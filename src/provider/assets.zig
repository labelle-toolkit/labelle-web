const std = @import("std");
pub const state_file = ".labelle-shell-state.json";
const State = struct { original: ?[]const u8, rendered: [64]u8 };
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
    if (project) |dir| {
        const src_real = try dir.realPathFileAlloc(io, ".", a);
        defer a.free(src_real);
        const out_real = try out.realPathFileAlloc(io, ".", a);
        defer a.free(out_real);
        if (within(out_real, src_real) or within(src_real, out_real)) return error.OverlappingShellDirectories;
        try copy(a, io, dir, out, true);
    }
    _ = try shell.stage(a, io, out, project);
    const rendered = (try optional(a, io, out, "index.html")).?;
    defer a.free(rendered);
    const saved = try std.json.Stringify.valueAlloc(a, State{ .original = original, .rendered = hash(rendered) }, .{});
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

fn copy(a: std.mem.Allocator, io: std.Io, src: std.Io.Dir, dst: std.Io.Dir, root: bool) !void {
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (root and std.mem.eql(u8, entry.name, "index.html")) continue;
        if (root) for ([_][]const u8{ "game.js", "game.wasm", "game.data", "index.html", "labelle-loader.js", "labelle-logo.png", state_file }) |reserved| {
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
                try copy(a, io, from, to, false);
            },
            else => return error.UnsupportedWebAsset,
        }
    }
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
