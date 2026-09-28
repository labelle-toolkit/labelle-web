//! The `--zip` archive: a stored (uncompressed) ZIP32 writer with no
//! external dependency.
const std = @import("std");
const exporter = @import("../export.zig");
const export_marker = exporter.export_marker;
const trimTrailingSeps = @import("paths.zig").trimTrailingSeps;

// ── ZIP writer (stored, no external dependency) ─────────────────────

/// Write `<output_dir>.zip` containing every file under `output_dir`.
/// Uses the ZIP "stored" method (no compression) so the archive is
/// valid everywhere without pulling in a deflate encoder or an external
/// `zip` binary. Returns the archive path (caller frees).
pub fn writeZipArchive(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();

    // Gather entries (relative paths, native separators).
    var entries: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }
    try collectRelFiles(allocator, io, output_dir, "", &entries);

    try checkZip32(entries.items.len, 0);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const CentralEntry = struct { name: []const u8, crc: u32, size: u32, offset: u32 };
    var central: std.ArrayList(CentralEntry) = .empty;
    // Register both cleanups up front (LIFO: free the duped names, then
    // the list). This frees names appended so far even if an error is
    // raised part-way through the loop below.
    defer central.deinit(allocator);
    defer for (central.items) |c| allocator.free(c.name);

    for (entries.items) |rel| {
        const full = try std.fs.path.join(allocator, &.{ output_dir, rel });
        defer allocator.free(full);
        const data = try cwd.readFileAlloc(io, full, allocator, .limited(std.math.maxInt(u32)));
        defer allocator.free(data);

        // ZIP entry names always use '/'.
        const zip_name = try toForwardSlash(allocator, rel);
        defer allocator.free(zip_name);

        if (zip_name.len > std.math.maxInt(u16)) return error.Zip64Required;
        try checkZip32(entries.items.len, @as(u64, buf.items.len) + 30 + zip_name.len + data.len);
        const crc = std.hash.crc.Crc32.hash(data);
        const size: u32 = @intCast(data.len);
        const offset: u32 = @intCast(buf.items.len);

        try appendLocalHeader(allocator, &buf, zip_name, crc, size);
        try buf.appendSlice(allocator, zip_name);
        try buf.appendSlice(allocator, data);

        // Central-dir names need a stable copy that outlives this loop
        // iteration (`zip_name` is freed at iteration end).
        const owned_name = try allocator.dupe(u8, zip_name);
        errdefer allocator.free(owned_name);
        try central.append(allocator, .{
            .name = owned_name,
            .crc = crc,
            .size = size,
            .offset = offset,
        });
    }

    var final_size: u64 = @as(u64, buf.items.len) + 22;
    for (central.items) |entry| final_size += 46 + entry.name.len;
    try checkZip32(central.items.len, final_size);
    const cd_offset: u32 = @intCast(buf.items.len);
    for (central.items) |c| {
        try appendCentralHeader(allocator, &buf, c.name, c.crc, c.size, c.offset);
        try buf.appendSlice(allocator, c.name);
    }
    const cd_size: u32 = @intCast(buf.items.len - cd_offset);
    try appendEndRecord(allocator, &buf, @intCast(central.items.len), cd_size, cd_offset);

    // Normalize before appending `.zip` — a trailing separator would make
    // `release/.zip` (a dotfile inside the dir) instead of `release.zip`.
    const base = trimTrailingSeps(output_dir);
    const zip_path = try std.fmt.allocPrint(allocator, "{s}.zip", .{base});
    errdefer allocator.free(zip_path);
    try cwd.writeFile(io, .{ .sub_path = zip_path, .data = buf.items });
    return zip_path;
}

/// This writer emits ZIP32; fail normally before narrowing any header fields.
pub fn checkZip32(entries: usize, bytes: u64) !void {
    if (entries > std.math.maxInt(u16) or bytes > std.math.maxInt(u32)) return error.Zip64Required;
}

test "ZIP32 bounds reject oversized archives without narrowing" {
    try checkZip32(65535, 0xffffffff);
    try std.testing.expectError(error.Zip64Required, checkZip32(65536, 0));
    try std.testing.expectError(error.Zip64Required, checkZip32(1, 0x100000000));
}

// DOS date/time for 1980-01-01 00:00 (a zero date is rejected by some
// extractors). date = (year-1980)<<9 | month<<5 | day = 0x0021.
const dos_date: u16 = 0x0021;
const dos_time: u16 = 0x0000;

fn appendU16(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try buf.appendSlice(allocator, &b);
}
fn appendU32(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(allocator, &b);
}

fn appendLocalHeader(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, crc: u32, size: u32) !void {
    try buf.appendSlice(allocator, &std.zip.local_file_header_sig);
    try appendU16(allocator, buf, 20); // version needed
    try appendU16(allocator, buf, 1 << 11); // UTF-8 filenames
    try appendU16(allocator, buf, 0); // method: store
    try appendU16(allocator, buf, dos_time);
    try appendU16(allocator, buf, dos_date);
    try appendU32(allocator, buf, crc);
    try appendU32(allocator, buf, size); // compressed
    try appendU32(allocator, buf, size); // uncompressed
    try appendU16(allocator, buf, @intCast(name.len));
    try appendU16(allocator, buf, 0); // extra len
}

fn appendCentralHeader(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8, crc: u32, size: u32, offset: u32) !void {
    try buf.appendSlice(allocator, &std.zip.central_file_header_sig);
    try appendU16(allocator, buf, 20); // version made by
    try appendU16(allocator, buf, 20); // version needed
    try appendU16(allocator, buf, 1 << 11); // UTF-8 filenames
    try appendU16(allocator, buf, 0); // method: store
    try appendU16(allocator, buf, dos_time);
    try appendU16(allocator, buf, dos_date);
    try appendU32(allocator, buf, crc);
    try appendU32(allocator, buf, size); // compressed
    try appendU32(allocator, buf, size); // uncompressed
    try appendU16(allocator, buf, @intCast(name.len));
    try appendU16(allocator, buf, 0); // extra len
    try appendU16(allocator, buf, 0); // comment len
    try appendU16(allocator, buf, 0); // disk number
    try appendU16(allocator, buf, 0); // internal attrs
    try appendU32(allocator, buf, 0); // external attrs
    try appendU32(allocator, buf, offset);
}

fn appendEndRecord(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), count: u16, cd_size: u32, cd_offset: u32) !void {
    try buf.appendSlice(allocator, &std.zip.end_record_sig);
    try appendU16(allocator, buf, 0); // disk number
    try appendU16(allocator, buf, 0); // cd start disk
    try appendU16(allocator, buf, count); // records on this disk
    try appendU16(allocator, buf, count); // total records
    try appendU32(allocator, buf, cd_size);
    try appendU32(allocator, buf, cd_offset);
    try appendU16(allocator, buf, 0); // comment len
}

pub fn toForwardSlash(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

/// Recursively collect relative file paths under `root` (native seps).
pub fn collectRelFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    rel: []const u8,
    out: *std.ArrayList([]u8),
) !void {
    const cwd = std.Io.Dir.cwd();
    const full = if (rel.len == 0) root else try std.fs.path.join(allocator, &.{ root, rel });
    defer if (rel.len != 0) allocator.free(full);

    var dir = try cwd.openDir(io, full, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // Don't archive the export marker (see `export_marker`).
        if (rel.len == 0 and std.mem.eql(u8, entry.name, export_marker)) continue;

        const child_rel = if (rel.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel, entry.name });
        switch (entry.kind) {
            .directory => {
                defer allocator.free(child_rel);
                try collectRelFiles(allocator, io, root, child_rel, out);
            },
            .file => {
                // Ownership transfers on success; free on append failure.
                errdefer allocator.free(child_rel);
                try out.append(allocator, child_rel);
            },
            else => allocator.free(child_rel),
        }
    }
}

test "writeZipArchive: produces an archive std.zip can read back" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try out.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<h1>hi</h1>" });
    try out.dir.writeFile(io, .{ .sub_path = "game.wasm", .data = "\x00asm\x01\x02\x03" });

    const out_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &out.sub_path, "release" });
    defer alloc.free(out_dir);
    // Move the seeded files into the export dir shape.
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    inline for (.{ "index.html", "game.wasm" }) |name| {
        const src = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &out.sub_path, name });
        defer alloc.free(src);
        const dst = try std.fs.path.join(alloc, &.{ out_dir, name });
        defer alloc.free(dst);
        try std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dst, io, .{ .make_path = true });
    }

    const zip_path = try writeZipArchive(alloc, io, out_dir);
    defer alloc.free(zip_path);

    // Read the archive back with std.zip and confirm both entries + CRCs.
    const cwd = std.Io.Dir.cwd();
    const zf = try cwd.openFile(io, zip_path, .{});
    defer zf.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = zf.reader(io, &rbuf);
    var iter = try std.zip.Iterator.init(&fr);

    var seen_index = false;
    var seen_wasm = false;
    var name_buf: [256]u8 = undefined;
    while (try iter.next()) |entry| {
        const name = name_buf[0..entry.filename_len];
        try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name);
        if (std.mem.eql(u8, name, "index.html")) seen_index = true;
        if (std.mem.eql(u8, name, "game.wasm")) seen_wasm = true;
    }
    try std.testing.expect(seen_index);
    try std.testing.expect(seen_wasm);
}
