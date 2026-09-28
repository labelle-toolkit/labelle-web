//! The export's ownership marker (`export_marker`): which output dirs and
//! neighbouring archives a previous export created, and may be replaced.
const std = @import("std");
const exporter = @import("../export.zig");
const export_marker = exporter.export_marker;
const trimTrailingSeps = @import("paths.zig").trimTrailingSeps;

pub const Ownership = struct { format: []const u8 = "labelle-web-export-v1", zip_sha256: ?[64]u8 = null };

pub fn recognizedMarker(data: []const u8) bool {
    if (std.mem.eql(u8, data, "labelle web export output dir\n")) return true;
    const Required = struct { format: []const u8, zip_sha256: ?[64]u8 = null };
    const parsed = std.json.parseFromSlice(Required, std.heap.page_allocator, data, .{}) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.format, "labelle-web-export-v1");
}

pub fn readOwnership(a: std.mem.Allocator, io: std.Io, output: []const u8) !Ownership {
    const path = try std.fs.path.join(a, &.{ output, export_marker });
    defer a.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return .{},
        else => return err,
    };
    defer a.free(data);
    // Old text-only markers do not establish ownership of an adjacent ZIP.
    const parsed = std.json.parseFromSlice(Ownership, a, data, .{}) catch return .{};
    defer parsed.deinit();
    return .{ .zip_sha256 = parsed.value.zip_sha256 };
}
pub fn writeOwnership(a: std.mem.Allocator, io: std.Io, marker: []const u8, value: Ownership) !void {
    const data = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(data);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = data });
}
pub fn hashFile(io: std.Io, path: []const u8) ![64]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
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
pub fn checkArchiveDestination(a: std.mem.Allocator, io: std.Io, output: []const u8, ownership: Ownership) !void {
    const path = try std.fmt.allocPrint(a, "{s}.zip", .{trimTrailingSeps(output)});
    defer a.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file or stat.nlink > 1) return error.DestructiveArchivePath;
    const expected = ownership.zip_sha256 orelse return error.DestructiveArchivePath;
    if (!std.mem.eql(u8, &expected, &try hashFile(io, path))) return error.DestructiveArchivePath;
}

/// True when `path` is a pre-existing, non-empty directory that no prior
/// export created (i.e. it lacks `export_marker`). Wiping such a dir
/// could destroy the user's files, so `packageExport` refuses. A missing
/// path, an empty dir, or a marker-bearing dir is safe (returns false).
pub fn outputDirIsUnsafe(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| return err != error.FileNotFound;
    defer dir.close(io);
    var it = dir.iterate();
    var empty = true;
    while (it.next(io) catch return true) |entry| {
        empty = false;
        if (!std.mem.eql(u8, entry.name, export_marker)) continue;
        if (entry.kind != .file) return true;
        const data = dir.readFileAlloc(io, export_marker, std.heap.page_allocator, .limited(1024)) catch return true;
        defer std.heap.page_allocator.free(data);
        return !recognizedMarker(data);
    }
    return !empty;
}

test "outputDirIsUnsafe: missing/empty/marked are safe, populated is not" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(base);

    // Missing path → safe.
    const missing = try std.fs.path.join(alloc, &.{ base, "nope" });
    defer alloc.free(missing);
    try std.testing.expect(!outputDirIsUnsafe(io, missing));

    // Empty dir → safe.
    try tmp.dir.createDirPath(io, "empty");
    const empty = try std.fs.path.join(alloc, &.{ base, "empty" });
    defer alloc.free(empty);
    try std.testing.expect(!outputDirIsUnsafe(io, empty));

    // Populated, no marker → UNSAFE (would clobber the user's files).
    try tmp.dir.createDirPath(io, "user");
    try tmp.dir.writeFile(io, .{ .sub_path = "user/keepme.txt", .data = "important" });
    const user = try std.fs.path.join(alloc, &.{ base, "user" });
    defer alloc.free(user);
    try std.testing.expect(outputDirIsUnsafe(io, user));

    // Populated WITH the export marker → safe (a prior export).
    try tmp.dir.writeFile(io, .{ .sub_path = "user/" ++ export_marker, .data = "labelle web export output dir\n" });
    try std.testing.expect(!outputDirIsUnsafe(io, user));
}
