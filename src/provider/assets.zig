const std = @import("std");
pub const state_file = ".labelle-shell-state.json";
const Custom = struct { path: []const u8, digest: [64]u8 };
const State = struct { schema: u8 = 1, original: ?[]const u8, rendered: [64]u8, custom: []const Custom = &.{}, directories: []const []const u8 = &.{} };
const Owned = struct {
    files: std.StringHashMap([64]u8),
    directories: std.StringHashMap(void),
    file_ids: std.AutoHashMap(std.Io.File.INode, void),
    directory_ids: std.AutoHashMap(std.Io.File.INode, void),
    legacy_directories: bool = false,
    fn init(a: std.mem.Allocator) Owned {
        return .{ .files = .init(a), .directories = .init(a), .file_ids = .init(a), .directory_ids = .init(a) };
    }
    fn deinit(self: *Owned) void {
        self.files.deinit();
        self.directories.deinit();
        self.file_ids.deinit();
        self.directory_ids.deinit();
    }
};
const shell = @import("../shell.zig");

/// Copy custom page resources and stamp the shell from its original source.
pub fn stage(a: std.mem.Allocator, io: std.Io, output_path: []const u8, project_web_path: ?[]const u8) !void {
    try preflight(a, io, output_path, project_web_path);
    const out = try std.Io.Dir.cwd().openDir(io, output_path, .{});
    defer out.close(io);
    // Reject output aliases before overwriting our owned files.
    for ([_][]const u8{ "index.html", "labelle-loader.js", "labelle-logo.png", state_file }) |name| try regularOrMissing(io, out, name);
    const current = try optional(a, io, out, "index.html");
    defer if (current) |text| a.free(text);
    var original: ?[]const u8 = current;
    var previous: ?std.json.Parsed(State) = null;
    defer if (previous) |value| value.deinit();
    if (try optional(a, io, out, state_file)) |saved| {
        defer a.free(saved);
        previous = try std.json.parseFromSlice(State, a, saved, .{ .allocate = .alloc_always });
        if (current) |text| {
            if (std.mem.eql(u8, &hash(text), &previous.?.value.rendered)) {
                original = previous.?.value.original;
                if (original) |source| try out.writeFile(io, .{ .sub_path = "index.html", .data = source }) else try out.deleteFile(io, "index.html");
            }
        }
    }
    const project = if (project_web_path) |path| std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    } else null;
    defer if (project) |dir| dir.close(io);
    var directories: std.ArrayList([]const u8) = .empty;
    defer {
        for (directories.items) |path| a.free(path);
        directories.deinit(a);
    }
    var copied: std.ArrayList(Custom) = .empty;
    defer {
        for (copied.items) |entry| a.free(entry.path);
        copied.deinit(a);
    }
    // Rebuild the overlay from a clean owned layer. Cleanup before copying
    // handles file/directory changes, compressed replacements and Unicode
    // case-only renames without guessing filesystem case-folding rules.
    if (previous) |state| {
        for (state.value.custom) |old| try removeStale(a, io, out, old.path, old.digest);
        if (state.value.schema < 2) {
            // Migrate pre-release provenance which did not record directories.
            for (state.value.custom) |old| {
                var parent = std.fs.path.dirname(old.path);
                while (parent) |path| {
                    if (path.len == 0) break;
                    try removeEmptyOwnedDir(io, out, path);
                    parent = std.fs.path.dirname(path);
                }
            }
        } else {
            var n = state.value.directories.len;
            while (n > 0) {
                n -= 1;
                try removeEmptyOwnedDir(io, out, state.value.directories[n]);
            }
        }
    }
    if (project) |dir| {
        const src_real = try dir.realPathFileAlloc(io, ".", a);
        defer a.free(src_real);
        const out_real = try out.realPathFileAlloc(io, ".", a);
        defer a.free(out_real);
        if (within(out_real, src_real) or within(src_real, out_real)) return error.OverlappingShellDirectories;
        try copy(a, io, dir, out, "", &copied, &directories);
    }
    _ = try shell.stage(a, io, out, project);
    const rendered = (try optional(a, io, out, "index.html")).?;
    defer a.free(rendered);
    const saved = try std.json.Stringify.valueAlloc(a, State{ .schema = 2, .original = original, .rendered = hash(rendered), .custom = copied.items, .directories = directories.items }, .{});
    defer a.free(saved);
    try out.writeFile(io, .{ .sub_path = state_file, .data = saved });
    // Stamping/loader updates invalidate precompressed copies.
    for ([_][]const u8{ "index.html", "labelle-loader.js", "labelle-logo.png" }) |name| try invalidateCompressed(a, io, out, name);
}

/// Validate the complete custom overlay before any file or provenance changes.
pub fn preflight(a: std.mem.Allocator, io: std.Io, output_path: []const u8, project_path: ?[]const u8) !void {
    const dst = try std.Io.Dir.cwd().openDir(io, output_path, .{});
    defer dst.close(io);
    var previous: ?std.json.Parsed(State) = null;
    defer if (previous) |value| value.deinit();
    var owned = Owned.init(a);
    defer owned.deinit();
    if (try optional(a, io, dst, state_file)) |saved| {
        defer a.free(saved);
        previous = try std.json.parseFromSlice(State, a, saved, .{ .allocate = .alloc_always });
        owned.legacy_directories = previous.?.value.schema < 2;
        for (previous.?.value.custom) |entry| {
            try owned.files.put(entry.path, entry.digest);
            const st = dst.statFile(io, entry.path, .{ .follow_symlinks = false }) catch continue;
            if (st.kind == .file and st.nlink == 1 and std.mem.eql(u8, &entry.digest, &try hashFile(io, dst, entry.path))) try owned.file_ids.put(st.inode, {});
        }
        for (previous.?.value.directories) |path_name| {
            try owned.directories.put(path_name, {});
            const st = dst.statFile(io, path_name, .{ .follow_symlinks = false }) catch continue;
            if (st.kind == .directory) try owned.directory_ids.put(st.inode, {});
        }
    }
    const path = project_path orelse return;
    const src = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src.close(io);
    const source = try src.realPathFileAlloc(io, ".", a);
    defer a.free(source);
    const output = try dst.realPathFileAlloc(io, ".", a);
    defer a.free(output);
    if (within(output, source) or within(source, output)) return error.OverlappingShellDirectories;
    try validateCustom(a, io, src, dst, "", &owned);
}
fn reserved(name: []const u8) bool {
    const base = compressedBase(name) orelse name;
    for ([_][]const u8{ "game.js", "game.wasm", "game.data", ".labelle-export", "index.html", "labelle-loader.js", "labelle-logo.png", state_file }) |owned| {
        if (std.ascii.eqlIgnoreCase(base, owned)) return true;
    }
    return false;
}
fn validateCustom(a: std.mem.Allocator, io: std.Io, src: std.Io.Dir, dst: ?std.Io.Dir, prefix: []const u8, owned: *const Owned) !void {
    const root = prefix.len == 0;
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (root and std.mem.eql(u8, entry.name, "index.html")) {
            if (entry.kind != .file) return error.UnsupportedWebAsset;
            continue;
        }
        if (root and reserved(entry.name)) return error.ReservedWebAsset;
        const path = try std.fs.path.join(a, &.{ prefix, entry.name });
        defer a.free(path);
        switch (entry.kind) {
            .file => if (dst) |dir| {
                const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                if (st) |existing| switch (existing.kind) {
                    .file => {},
                    .directory => {
                        const tree = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                        defer tree.close(io);
                        if (!try ownedTreeOnly(a, io, tree, path, owned)) return error.InvalidWebAssetDestination;
                    },
                    else => return error.InvalidWebAssetDestination,
                };
            },
            .directory => {
                const from = try src.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer from.close(io);
                var to: ?std.Io.Dir = null;
                if (dst) |dir| {
                    const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                        error.FileNotFound => null,
                        else => return err,
                    };
                    if (st) |existing| {
                        if (existing.kind == .directory) {
                            to = try dir.openDir(io, entry.name, .{ .follow_symlinks = false });
                        } else if (existing.kind != .file or !try ownedFile(io, dir, entry.name, path, owned)) return error.InvalidWebAssetDestination;
                    }
                }
                defer if (to) |dir| dir.close(io);
                try validateCustom(a, io, from, to, path, owned);
            },
            else => return error.UnsupportedWebAsset,
        }
    }
}

fn ownedFile(io: std.Io, dir: std.Io.Dir, name: []const u8, path: []const u8, owned: *const Owned) !bool {
    if (owned.files.get(path)) |digest| return std.mem.eql(u8, &digest, &try hashFile(io, dir, name));
    const st = try dir.statFile(io, name, .{ .follow_symlinks = false });
    return st.kind == .file and st.nlink == 1 and owned.file_ids.contains(st.inode);
}
fn ownedTreeOnly(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, prefix: []const u8, owned: *const Owned) !bool {
    var has_owned = owned.directories.contains(prefix) or owned.directory_ids.contains((try dir.statFile(io, ".", .{})).inode);
    if (!has_owned and owned.legacy_directories) {
        var keys = owned.files.keyIterator();
        while (keys.next()) |key| {
            if (within(key.*, prefix) and key.len > prefix.len) {
                has_owned = true;
                break;
            }
        }
    }
    if (!has_owned) return false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const path = try std.fs.path.join(a, &.{ prefix, entry.name });
        defer a.free(path);
        switch (entry.kind) {
            .file => if (!try ownedFile(io, dir, entry.name, path, owned)) return false,
            .directory => {
                const child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                if (!try ownedTreeOnly(a, io, child, path, owned)) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn compressedBase(name: []const u8) ?[]const u8 {
    if (std.ascii.endsWithIgnoreCase(name, ".gz") or std.ascii.endsWithIgnoreCase(name, ".br")) return name[0 .. name.len - 3];
    return null;
}
fn invalidateCompressed(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    for ([_][]const u8{ ".gz", ".br" }) |ext| {
        const path = try std.mem.concat(a, u8, &.{ name, ext });
        defer a.free(path);
        dir.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn within(child: []const u8, parent: []const u8) bool {
    const prefix = if (@import("builtin").os.tag == .windows) std.ascii.startsWithIgnoreCase(child, parent) else std.mem.startsWith(u8, child, parent);
    return prefix and (child.len == parent.len or (child.len > parent.len and (std.fs.path.isSep(parent[parent.len - 1]) or std.fs.path.isSep(child[parent.len]))));
}

fn copy(a: std.mem.Allocator, io: std.Io, src: std.Io.Dir, dst: std.Io.Dir, prefix: []const u8, copied: *std.ArrayList(Custom), directories: *std.ArrayList([]const u8)) !void {
    const root = prefix.len == 0;
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (root and std.mem.eql(u8, entry.name, "index.html")) continue;
        if (root and reserved(entry.name)) return error.ReservedWebAsset;
        switch (entry.kind) {
            .file => {
                // The uncompressed source wins. Do not reintroduce an old
                // sibling later merely because directory iteration saw it last.
                if (compressedBase(entry.name)) |base| {
                    if (src.statFile(io, base, .{})) |st| {
                        if (st.kind == .file) continue;
                    } else |err| switch (err) {
                        error.FileNotFound => {},
                        else => return err,
                    }
                }
                try regularOrMissing(io, dst, entry.name);
                try src.copyFile(entry.name, dst, entry.name, io, .{});
                try invalidateCompressed(a, io, dst, entry.name);
                const path = try std.fs.path.join(a, &.{ prefix, entry.name });
                errdefer a.free(path);
                try copied.append(a, .{ .path = path, .digest = try hashFile(io, dst, entry.name) });
            },
            .directory => {
                var created = false;
                if (dst.statFile(io, entry.name, .{ .follow_symlinks = false })) |st| {
                    if (st.kind != .directory) return error.InvalidWebAssetDestination;
                } else |err| switch (err) {
                    error.FileNotFound => {
                        created = true;
                    },
                    else => return err,
                }
                try dst.createDirPath(io, entry.name);
                const from = try src.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer from.close(io);
                const to = try dst.openDir(io, entry.name, .{});
                defer to.close(io);
                const child = try std.fs.path.join(a, &.{ prefix, entry.name });
                defer a.free(child);
                if (created) {
                    const owned_path = try a.dupe(u8, child);
                    directories.append(a, owned_path) catch |err| {
                        a.free(owned_path);
                        return err;
                    };
                }
                try copy(a, io, from, to, child, copied, directories);
            },
            else => return error.UnsupportedWebAsset,
        }
    }
}

/// Remove only our unchanged copies. A backend may have emitted a new file
/// since staging; a differing digest belongs to that newer build and survives.
/// Resolve one component at a time without following symlinks from stale state.
fn removeStale(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, digest: [64]u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or (@import("builtin").os.tag == .windows and std.mem.indexOfScalar(u8, path, ':') != null)) return error.InvalidAssetProvenance;
    const sep = std.mem.indexOfAny(u8, path, if (@import("builtin").os.tag == .windows) "/\\" else "/");
    const head = path[0 .. sep orelse path.len];
    if (head.len == 0 or std.mem.eql(u8, head, ".") or std.mem.eql(u8, head, "..")) return error.InvalidAssetProvenance;
    const st = dir.statFile(io, head, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (sep) |at| {
        if (st.kind == .file) return; // a backend replaced the old parent tree
        if (st.kind != .directory) return error.InvalidWebAssetDestination;
        const child = try dir.openDir(io, head, .{ .follow_symlinks = false });
        defer child.close(io);
        return removeStale(a, io, child, path[at + 1 ..], digest);
    }
    if (st.kind == .directory) return; // a backend replaced this custom file
    if (st.kind != .file) return error.InvalidWebAssetDestination;
    if (!std.mem.eql(u8, &digest, &try hashFile(io, dir, head))) return;
    try dir.deleteFile(io, head);
    try invalidateCompressed(a, io, dir, head);
}
/// Remove only an empty recorded directory, never following a stale alias.
fn removeEmptyOwnedDir(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or (@import("builtin").os.tag == .windows and std.mem.indexOfScalar(u8, path, ':') != null)) return error.InvalidAssetProvenance;
    const sep = std.mem.indexOfAny(u8, path, if (@import("builtin").os.tag == .windows) "/\\" else "/");
    const head = path[0 .. sep orelse path.len];
    if (head.len == 0 or std.mem.eql(u8, head, ".") or std.mem.eql(u8, head, "..")) return error.InvalidAssetProvenance;
    const st = dir.statFile(io, head, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (st.kind != .directory) return;
    if (sep) |at| {
        const child = try dir.openDir(io, head, .{ .follow_symlinks = false });
        defer child.close(io);
        return removeEmptyOwnedDir(io, child, path[at + 1 ..]);
    }
    dir.deleteDir(io, head) catch |err| switch (err) {
        error.FileNotFound, error.DirNotEmpty => {},
        else => return err,
    };
}

fn hashFile(io: std.Io, dir: std.Io.Dir, path: []const u8) ![64]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var chunk: [8192]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        hasher.update(chunk[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
fn regularOrMissing(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    if (dir.statFile(io, name, .{ .follow_symlinks = false })) |st| {
        if (st.kind != .file) return error.InvalidWebAssetDestination;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}
fn optional(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !?[]u8 {
    return dir.readFileAlloc(io, name, a, .limited(if (std.mem.eql(u8, name, state_file)) 6 * 16 * 1024 * 1024 + 1024 else 16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}
