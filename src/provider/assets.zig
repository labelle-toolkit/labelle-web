const std = @import("std");
pub const state_file = ".labelle-shell-state.json";
const Custom = struct { path: []const u8, digest: [64]u8 };
const State = struct { original: ?[]const u8, rendered: [64]u8, custom: []const Custom = &.{} };
const shell = @import("../shell.zig");

/// Copy custom page resources and stamp the shell from its original source.
pub fn stage(a: std.mem.Allocator, io: std.Io, output_path: []const u8, project_web_path: ?[]const u8) !void {
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
    const project = if (project_web_path) |path| std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    } else null;
    defer if (project) |dir| dir.close(io);
    var copied: std.ArrayList(Custom) = .empty;
    defer {
        for (copied.items) |entry| a.free(entry.path);
        copied.deinit(a);
    }
    if (project) |dir| {
        const src_real = try dir.realPathFileAlloc(io, ".", a);
        defer a.free(src_real);
        const out_real = try out.realPathFileAlloc(io, ".", a);
        defer a.free(out_real);
        if (within(out_real, src_real) or within(src_real, out_real)) return error.OverlappingShellDirectories;
        try copy(a, io, dir, out, "", &copied);
    }
    if (previous) |state| for (state.value.custom) |old| {
        var retained = false;
        for (copied.items) |entry| {
            if (std.mem.eql(u8, old.path, entry.path)) {
                retained = true;
                break;
            }
            // Case-only renames can refer to the same destination on a
            // case-insensitive volume. Do not delete the freshly copied file.
            if (std.ascii.eqlIgnoreCase(old.path, entry.path)) {
                const old_stat = out.statFile(io, old.path, .{ .follow_symlinks = false }) catch continue;
                const new_stat = try out.statFile(io, entry.path, .{ .follow_symlinks = false });
                if (old_stat.inode == new_stat.inode) {
                    retained = true;
                    break;
                }
            }
        }
        if (!retained) try removeStale(a, io, out, old.path, old.digest);
    };
    _ = try shell.stage(a, io, out, project);
    const rendered = (try optional(a, io, out, "index.html")).?;
    defer a.free(rendered);
    const saved = try std.json.Stringify.valueAlloc(a, State{ .original = original, .rendered = hash(rendered), .custom = copied.items }, .{});
    defer a.free(saved);
    try out.writeFile(io, .{ .sub_path = state_file, .data = saved });
    // Stamping/loader updates invalidate precompressed copies.
    for ([_][]const u8{ "index.html", "labelle-loader.js", "labelle-logo.png" }) |name| try invalidateCompressed(a, io, out, name);
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

fn copy(a: std.mem.Allocator, io: std.Io, src: std.Io.Dir, dst: std.Io.Dir, prefix: []const u8, copied: *std.ArrayList(Custom)) !void {
    const root = prefix.len == 0;
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (root and std.mem.eql(u8, entry.name, "index.html")) continue;
        if (root) for ([_][]const u8{ "game.js", "game.wasm", "game.data", ".labelle-export", "index.html", "labelle-loader.js", "labelle-logo.png", state_file }) |reserved| {
            const name = compressedBase(entry.name) orelse entry.name;
            if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ReservedWebAsset;
        };
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
                if (dst.statFile(io, entry.name, .{ .follow_symlinks = false })) |st| {
                    if (st.kind != .directory) return error.InvalidWebAssetDestination;
                } else |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                }
                try dst.createDirPath(io, entry.name);
                const from = try src.openDir(io, entry.name, .{ .iterate = true });
                defer from.close(io);
                const to = try dst.openDir(io, entry.name, .{});
                defer to.close(io);
                const child = try std.fs.path.join(a, &.{ prefix, entry.name });
                defer a.free(child);
                try copy(a, io, from, to, child, copied);
            },
            else => return error.UnsupportedWebAsset,
        }
    }
}

/// Remove only our unchanged copies. A backend may have emitted a new file
/// since staging; a differing digest belongs to that newer build and survives.
/// Resolve one component at a time without following symlinks from stale state.
fn removeStale(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, digest: [64]u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, ':') != null) return error.InvalidAssetProvenance;
    const sep = std.mem.indexOfAny(u8, path, "/\\");
    const head = path[0 .. sep orelse path.len];
    if (head.len == 0 or std.mem.eql(u8, head, ".") or std.mem.eql(u8, head, "..")) return error.InvalidAssetProvenance;
    const st = dir.statFile(io, head, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (sep) |at| {
        if (st.kind != .directory) return error.InvalidWebAssetDestination;
        const child = try dir.openDir(io, head, .{ .follow_symlinks = false });
        defer child.close(io);
        return removeStale(a, io, child, path[at + 1 ..], digest);
    }
    if (st.kind != .file) return error.InvalidWebAssetDestination;
    if (!std.mem.eql(u8, &digest, &try hashFile(io, dir, head))) return;
    try dir.deleteFile(io, head);
    try invalidateCompressed(a, io, dir, head);
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
