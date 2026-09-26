//! Web export packaging, extracted from labelle-cli at 5eccdbc.
//! Copy, optimize, stage the branded/custom shell, then package the final bytes.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// Marker file written into the output dir. Its presence tells a later
/// run that the dir is a labelle export (safe to wipe + recreate). A
/// pre-existing non-empty dir WITHOUT this marker is refused — see
/// `outputDirIsUnsafe` — so `--output <a dir with your stuff>` can't
/// silently delete unrelated files.
pub const export_marker = ".labelle-export";

/// Deployment target for `--platform`. `none` is the plain export.
pub const Platform = enum { none, itch, github_pages };

/// Parse the `--platform` value. Accepts both `github-pages` (the
/// documented spelling) and `github_pages`.
pub fn parsePlatform(val: []const u8) ?Platform {
    if (std.mem.eql(u8, val, "itch")) return .itch;
    if (std.mem.eql(u8, val, "github-pages") or std.mem.eql(u8, val, "github_pages")) return .github_pages;
    return null;
}

pub const Options = struct {
    /// Destination dir (cwd-relative or absolute). Wiped + recreated.
    output_dir: []const u8,
    zip: bool = false,
    platform: Platform = .none,
};

/// A packaged file and its size before/after optimization. `before` ==
/// `after` for everything except `.wasm` files that `wasm-opt` shrank.
const FileReport = struct {
    rel: []const u8,
    before: u64,
    after: u64,
};

/// Package the built WASM output at `web_dir` into `opts.output_dir`.
/// `project_web_dir` is the durable `<project>/web` shell dir (or null);
/// its `index.html`, when present, wins as the root page.
pub fn packageExport(
    allocator: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    opts: Options,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // Commands package an existing build; they do not invoke a compiler.
    cwd.access(io, web_dir, .{}) catch {
        std.debug.print(
            "labelle web export: no WASM build output at '{s}'\n" ++
                "  run `labelle build --platform=wasm` first.\n",
            .{web_dir},
        );
        return error.BuildFailed;
    };

    try validateBuildTree(io, cwd, web_dir);
    try @import("assets.zig").preflight(allocator, io, web_dir, project_web_dir);

    // Safety gate 1: refuse an output that names an existing regular FILE.
    // `outputDirIsUnsafe` can't see this (its `openDir` just fails), so the
    // wipe below would silently delete the user's file and replace it with
    // a directory.
    if (cwd.statFile(io, opts.output_dir, .{})) |st| {
        if (st.kind != .directory) {
            std.debug.print(
                "labelle web export: --output '{s}' is a file, not a directory\n" ++
                    "  choose a directory path, e.g. --output ./release\n",
                .{opts.output_dir},
            );
            return error.DestructiveOutputPath;
        }
    } else |_| {}

    // Safety gate 2: refuse an output nested inside the build's web output.
    // Copying `web_dir` into a directory that lives under `web_dir` would
    // recursively copy the source into itself.
    if (try pathIsWithin(allocator, opts.output_dir, web_dir) or try pathIsWithin(allocator, web_dir, opts.output_dir)) {
        std.debug.print(
            "labelle web export: --output '{s}' is inside the build output '{s}'\n" ++
                "  choose a destination outside the web build dir, e.g. --output ./release\n",
            .{ opts.output_dir, web_dir },
        );
        return error.DestructiveOutputPath;
    }

    // Safety gate 3: refuse to wipe a pre-existing, non-empty dir that no
    // prior export created. `resolveExportOutput` (cli.zig) already rejects
    // the cwd/project root and ancestors; this is the complementary guard.
    if (outputDirIsUnsafe(io, opts.output_dir)) {
        std.debug.print(
            "labelle web export: refusing to overwrite non-empty '{s}'\n" ++
                "  it wasn't created by a previous export (no {s} marker).\n" ++
                "  choose an empty/dedicated dir, or delete it yourself first.\n",
            .{ opts.output_dir, export_marker },
        );
        return error.DestructiveOutputPath;
    }

    // A neighboring archive is a separate destination. Only overwrite bytes
    // whose digest matches the previous export's private ownership record.
    const ownership = try readOwnership(allocator, io, opts.output_dir);
    if (opts.zip) try checkArchiveDestination(allocator, io, opts.output_dir, ownership);

    // Fresh output dir — never leak stale files from a prior export. A wipe
    // failure is fatal: proceeding would blend stale files into the release.
    cwd.deleteTree(io, opts.output_dir) catch |err| {
        std.debug.print(
            "labelle web export: could not clear output dir '{s}': {s}\n",
            .{ opts.output_dir, @errorName(err) },
        );
        return err;
    };
    try cwd.createDirPath(io, opts.output_dir);
    // Drop the marker immediately so even a partial/failed export is
    // recognized as ours on the next run (and excluded from the archive).
    const marker_path = try std.fs.path.join(allocator, &.{ opts.output_dir, export_marker });
    defer allocator.free(marker_path);
    try writeOwnership(allocator, io, marker_path, ownership);

    // 1. Copy the whole web tree.
    var files: std.ArrayList(FileReport) = .empty;
    defer {
        for (files.items) |f| allocator.free(f.rel);
        files.deinit(allocator);
    }
    try copyTree(allocator, io, web_dir, opts.output_dir, &files);

    // 2. Best-effort wasm-opt -O3 on each .wasm.
    const wasm_opt_ran = try optimizeWasm(allocator, io, opts.output_dir, &files);
    // Stamp AFTER optimization, so the download total describes shipped bytes.
    try ensureIndexHtml(allocator, io, web_dir, project_web_dir, opts.output_dir, &files);

    // Build-only provenance must not ship in a public export.
    const state_path = try std.fs.path.join(allocator, &.{ opts.output_dir, @import("assets.zig").state_file });
    defer allocator.free(state_path);
    try cwd.deleteFile(io, state_path);

    // 4. Per-platform touches.
    switch (opts.platform) {
        .github_pages => {
            // GitHub Pages runs Jekyll by default, which drops files/dirs
            // starting with `_`. `.nojekyll` disables that so emcc's
            // support files always ship.
            const nojekyll = try std.fs.path.join(allocator, &.{ opts.output_dir, ".nojekyll" });
            defer allocator.free(nojekyll);
            try cwd.writeFile(io, .{ .sub_path = nojekyll, .data = "" });
        },
        .itch, .none => {},
    }

    // 5. Optional zip archive.
    var zip_path: ?[]const u8 = null;
    defer if (zip_path) |p| allocator.free(p);
    if (opts.zip) {
        zip_path = try writeZipArchive(allocator, io, opts.output_dir);
        try writeOwnership(allocator, io, marker_path, .{ .zip_sha256 = try hashFile(io, zip_path.?) });
    }

    // Report the shipped tree, including custom assets and excluding removed
    // compressed/provenance files. Keep original wasm sizes for savings.
    try refreshReport(allocator, io, opts.output_dir, &files);
    printReport(files.items, opts, wasm_opt_ran, zip_path);
}

const Ownership = struct { format: []const u8 = "labelle-web-export-v1", zip_sha256: ?[64]u8 = null };

/// Refuse unsupported entries before clearing any existing destination.
pub fn validateBuildTree(io: std.Io, parent: std.Io.Dir, path: []const u8) !void {
    return validateTree(io, parent, path, true);
}
fn validateTree(io: std.Io, parent: std.Io.Dir, path: []const u8, root: bool) !void {
    const dir = try parent.openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (root and std.ascii.eqlIgnoreCase(entry.name, export_marker)) return error.ReservedWebAsset;
        switch (entry.kind) {
            .directory => try validateTree(io, dir, entry.name, false),
            .file => {},
            else => return error.UnsupportedBuildArtifact,
        }
    }
}

fn recognizedMarker(data: []const u8) bool {
    if (std.mem.eql(u8, data, "labelle web export output dir\n")) return true;
    const Required = struct { format: []const u8, zip_sha256: ?[64]u8 = null };
    const parsed = std.json.parseFromSlice(Required, std.heap.page_allocator, data, .{}) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.format, "labelle-web-export-v1");
}

fn readOwnership(a: std.mem.Allocator, io: std.Io, output: []const u8) !Ownership {
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
fn writeOwnership(a: std.mem.Allocator, io: std.Io, marker: []const u8, value: Ownership) !void {
    const data = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(data);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = data });
}
fn hashFile(io: std.Io, path: []const u8) ![64]u8 {
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
fn checkArchiveDestination(a: std.mem.Allocator, io: std.Io, output: []const u8, ownership: Ownership) !void {
    const path = try std.fmt.allocPrint(a, "{s}.zip", .{trimTrailingSeps(output)});
    defer a.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return error.DestructiveArchivePath;
    const expected = ownership.zip_sha256 orelse return error.DestructiveArchivePath;
    if (!std.mem.eql(u8, &expected, &try hashFile(io, path))) return error.DestructiveArchivePath;
}

fn refreshReport(a: std.mem.Allocator, io: std.Io, root: []const u8, files: *std.ArrayList(FileReport)) !void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| a.free(path);
        paths.deinit(a);
    }
    try collectRelFiles(a, io, root, "", &paths);
    var fresh: std.ArrayList(FileReport) = .empty;
    errdefer {
        for (fresh.items) |file| a.free(file.rel);
        fresh.deinit(a);
    }
    for (paths.items) |path| {
        const full = try std.fs.path.join(a, &.{ root, path });
        defer a.free(full);
        const size = fileSize(io, full);
        var before = size;
        for (files.items) |old| {
            if (std.mem.eql(u8, old.rel, path)) {
                before = old.before;
                break;
            }
        }
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        try fresh.append(a, .{ .rel = owned, .before = before, .after = size });
    }
    for (files.items) |file| a.free(file.rel);
    files.deinit(a);
    files.* = fresh;
}

/// Recursively copy every file under `src_root` into `dst_root`,
/// recording each in `out`. Directory structure is recreated on demand
/// (`copyFile` with `make_path`).
fn copyTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    src_root: []const u8,
    dst_root: []const u8,
    out: *std.ArrayList(FileReport),
) !void {
    try walkInto(allocator, io, src_root, dst_root, "", out);
}

fn walkInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    src_root: []const u8,
    dst_root: []const u8,
    rel: []const u8,
    out: *std.ArrayList(FileReport),
) !void {
    const cwd = std.Io.Dir.cwd();
    const src_full = if (rel.len == 0) src_root else try std.fs.path.join(allocator, &.{ src_root, rel });
    defer if (rel.len != 0) allocator.free(src_full);

    var dir = try cwd.openDir(io, src_full, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_rel = if (rel.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel, entry.name });

        switch (entry.kind) {
            .directory => {
                defer allocator.free(child_rel);
                try walkInto(allocator, io, src_root, dst_root, child_rel, out);
            },
            .file => {
                // `child_rel` ownership transfers into `out` on success;
                // free it if any step before the append fails.
                errdefer allocator.free(child_rel);
                const src_path = try std.fs.path.join(allocator, &.{ src_root, child_rel });
                defer allocator.free(src_path);
                const dst_path = try std.fs.path.join(allocator, &.{ dst_root, child_rel });
                defer allocator.free(dst_path);

                try cwd.copyFile(src_path, cwd, dst_path, io, .{ .make_path = true });
                const size = fileSize(io, dst_path);
                try out.append(allocator, .{ .rel = child_rel, .before = size, .after = size });
            },
            else => allocator.free(child_rel),
        }
    }
}

/// Stage the project, emitted or default shell after optimization, with the
/// final raw wasm size and the custom page's relative resources.
fn ensureIndexHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    output_dir: []const u8,
    files: *std.ArrayList(FileReport),
) !void {
    _ = web_dir;
    try @import("assets.zig").stage(allocator, io, output_dir, project_web_dir);
    for ([_][]const u8{ "index.html", "labelle-loader.js", "labelle-logo.png" }) |name| {
        const path = try std.fs.path.join(allocator, &.{ output_dir, name });
        defer allocator.free(path);
        try recordOrUpdate(allocator, files, name, fileSize(io, path));
    }
}

/// Best-effort `wasm-opt -O3` over every top-level `.wasm` in
/// `output_dir`. Returns true if at least one file was optimized.
/// Missing `wasm-opt` (not on PATH) is not an error — the export just
/// ships the un-optimized wasm.
fn optimizeWasm(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    files: *std.ArrayList(FileReport),
) !bool {
    const cwd = std.Io.Dir.cwd();
    const scratch = try optimizerScratch(allocator, io, output_dir);
    defer allocator.free(scratch);
    defer cwd.deleteTree(io, scratch) catch {};
    var any = false;
    for (files.items) |*f| {
        if (!std.mem.endsWith(u8, f.rel, ".wasm")) continue;

        const in_path = try std.fs.path.join(allocator, &.{ output_dir, f.rel });
        defer allocator.free(in_path);
        const out_path = try std.fs.path.join(allocator, &.{ scratch, "optimized.wasm" });
        defer allocator.free(out_path);

        const result = std.process.run(allocator, io, .{
            .argv = &.{ "wasm-opt", "-O3", "--strip-debug", in_path, "-o", out_path },
        }) catch {
            // Spawn failure (wasm-opt absent) or IO error — leave the
            // wasm as-is and stop trying.
            return any;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const ok = switch (result.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (!ok) {
            cwd.deleteFile(io, out_path) catch {};
            continue;
        }

        // Swap the optimized file in.
        cwd.rename(out_path, cwd, in_path, io) catch {
            cwd.deleteFile(io, out_path) catch {};
            continue;
        };
        for ([_][]const u8{ ".gz", ".br" }) |ext| {
            const stale = try std.mem.concat(allocator, u8, &.{ in_path, ext });
            defer allocator.free(stale);
            cwd.deleteFile(io, stale) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        f.after = fileSize(io, in_path);
        any = true;
    }
    return any;
}

/// An exclusively created sibling directory stays outside the shipped tree.
fn optimizerScratch(a: std.mem.Allocator, io: std.Io, output: []const u8) ![]const u8 {
    while (true) {
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = try std.fmt.allocPrint(a, "{s}.wasm-opt-{s}", .{ trimTrailingSeps(output), std.fmt.bytesToHex(random, .lower) });
        std.Io.Dir.cwd().createDir(io, name, .default_dir) catch |err| {
            a.free(name);
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        return name;
    }
}

/// Update an existing report row's `after` size, or append a new one.
/// Used when a file (index.html) is written after the initial copy walk.
fn recordOrUpdate(
    allocator: std.mem.Allocator,
    files: *std.ArrayList(FileReport),
    rel: []const u8,
    size: u64,
) !void {
    for (files.items) |*f| {
        if (std.mem.eql(u8, f.rel, rel)) {
            // A replacement copy (e.g. the project shell overwriting the
            // emitted stub) — reset BOTH sizes so the report shows the
            // current size, never a stale before→after delta (which would
            // also underflow `before - after` when the file grew).
            f.before = size;
            f.after = size;
            return;
        }
    }
    const owned = try allocator.dupe(u8, rel);
    errdefer allocator.free(owned);
    try files.append(allocator, .{ .rel = owned, .before = size, .after = size });
}

// ── ZIP writer (stored, no external dependency) ─────────────────────

/// Write `<output_dir>.zip` containing every file under `output_dir`.
/// Uses the ZIP "stored" method (no compression) so the archive is
/// valid everywhere without pulling in a deflate encoder or an external
/// `zip` binary. Returns the archive path (caller frees).
fn writeZipArchive(allocator: std.mem.Allocator, io: std.Io, output_dir: []const u8) ![]const u8 {
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
        const data = try cwd.readFileAlloc(io, full, allocator, .limited(1024 * 1024 * 1024));
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
fn checkZip32(entries: usize, bytes: u64) !void {
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

fn toForwardSlash(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

/// Recursively collect relative file paths under `root` (native seps).
fn collectRelFiles(
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

// ── Reporting ───────────────────────────────────────────────────────

fn printReport(items: []const FileReport, opts: Options, wasm_opt_ran: bool, zip_path: ?[]const u8) void {
    var total_before: u64 = 0;
    var total_after: u64 = 0;
    for (items) |f| {
        total_before += f.before;
        total_after += f.after;
    }

    std.debug.print("\nWASM Export Complete!\n\n", .{});
    var bbuf: [32]u8 = undefined;
    var abuf: [32]u8 = undefined;
    for (items) |f| {
        // Only render a before→after delta when the file actually shrank
        // (wasm-opt). `f.after < f.before` also guards `before - after`
        // against unsigned underflow.
        if (f.after < f.before) {
            const pct = if (f.before == 0) 0 else (100 * (f.before - f.after)) / f.before;
            std.debug.print("  {s}: {s} -> {s} ({d}% smaller)\n", .{
                f.rel, formatSize(&bbuf, f.before), formatSize(&abuf, f.after), pct,
            });
        } else {
            std.debug.print("  {s}: {s}\n", .{ f.rel, formatSize(&abuf, f.after) });
        }
    }
    std.debug.print("  Total: {s}\n\n", .{formatSize(&abuf, total_after)});

    if (!wasm_opt_ran) {
        std.debug.print("  note: wasm-opt not found on PATH — shipping un-optimized .wasm\n", .{});
        std.debug.print("        install binaryen (`wasm-opt`) for a smaller build\n", .{});
    }
    std.debug.print("  Output: {s}/\n", .{opts.output_dir});
    if (zip_path) |p| std.debug.print("  Archive: {s}\n", .{p});

    switch (opts.platform) {
        .itch => {
            std.debug.print("  Ready for itch.io — upload the {s}.\n", .{
                if (zip_path != null) "archive" else "folder as a zip (add --zip)",
            });
        },
        .github_pages => std.debug.print("  Ready for GitHub Pages (added .nojekyll).\n", .{}),
        .none => std.debug.print("  Ready to deploy!\n", .{}),
    }
}

/// Human-readable size. Mirrors the issue's report ("245 KB").
fn formatSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "?";
    }
    if (bytes >= 1024) {
        return std.fmt.bufPrint(buf, "{d} KB", .{bytes / 1024}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
}

// ── path helpers ────────────────────────────────────────────────────

/// Path-boundary equality, case-insensitive on Windows (whose
/// filesystems are case-insensitive).
fn pathEql(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(a, b)
    else
        std.mem.eql(u8, a, b);
}

/// Strip trailing path separators (keeping at least one char) so a value
/// like `release/` yields `release` before a suffix is appended.
/// `isSep` is platform-aware: on Windows both `/` and `\` are stripped;
/// on POSIX only `/` (a `\` there is a legitimate filename byte).
fn trimTrailingSeps(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and std.fs.path.isSep(path[end - 1])) end -= 1;
    return path[0..end];
}

/// True when `inner` is `outer` or nested under it. Both are normalized
/// (`resolve` collapses `.`/`..` and unifies separators to the platform's
/// own) so `a/b/../out` vs `a/out`, and mixed `/`+`\` on Windows, compare
/// correctly. Paths are compared as-passed (both cwd-relative here), so
/// no filesystem access is needed.
fn pathIsWithin(allocator: std.mem.Allocator, inner_raw: []const u8, outer_raw: []const u8) !bool {
    const inner = try std.fs.path.resolve(allocator, &.{inner_raw});
    defer allocator.free(inner);
    const outer = try std.fs.path.resolve(allocator, &.{outer_raw});
    defer allocator.free(outer);
    if (pathEql(inner, outer)) return true;
    return inner.len > outer.len and
        pathEql(inner[0..outer.len], outer) and
        std.fs.path.isSep(inner[outer.len]);
}

// ── small IO helpers ────────────────────────────────────────────────

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
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

fn fileSize(io: std.Io, path: []const u8) u64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.size;
}

// ── Tests ───────────────────────────────────────────────────────────

test "parsePlatform: known + unknown" {
    try std.testing.expectEqual(Platform.itch, parsePlatform("itch").?);
    try std.testing.expectEqual(Platform.github_pages, parsePlatform("github-pages").?);
    try std.testing.expectEqual(Platform.github_pages, parsePlatform("github_pages").?);
    try std.testing.expect(parsePlatform("nope") == null);
    try std.testing.expect(parsePlatform("") == null);
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

test "formatSize: byte/KB/MB thresholds" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", formatSize(&buf, 512));
    try std.testing.expectEqualStrings("2 KB", formatSize(&buf, 2048));
    try std.testing.expectEqualStrings("1.5 MB", formatSize(&buf, 1024 * 1024 * 3 / 2));
}

test "trimTrailingSeps: strips trailing separators" {
    try std.testing.expectEqualStrings("release", trimTrailingSeps("release/"));
    try std.testing.expectEqualStrings("release", trimTrailingSeps("release///"));
    try std.testing.expectEqualStrings("a/b", trimTrailingSeps("a/b"));
    try std.testing.expectEqualStrings("/", trimTrailingSeps("/"));
}

test "pathIsWithin: nesting detection" {
    const a = std.testing.allocator;
    try std.testing.expect(try pathIsWithin(a, "web/out", "web"));
    try std.testing.expect(try pathIsWithin(a, "web", "web"));
    try std.testing.expect(try pathIsWithin(a, "web/a/../out", "web"));
    try std.testing.expect(!try pathIsWithin(a, "release", "web"));
    // "webby" must not count as inside "web" (boundary check).
    try std.testing.expect(!try pathIsWithin(a, "webby", "web"));
}

test "pathIsWithin: Windows backslash + case-insensitive nesting" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // Backslash + mixed separators normalize to the same tree.
    try std.testing.expect(try pathIsWithin(a, "web\\out", "web"));
    try std.testing.expect(try pathIsWithin(a, "web/out\\deep", "web"));
    // Case-insensitive: WEB\out is inside web.
    try std.testing.expect(try pathIsWithin(a, "WEB\\out", "web"));
    // Boundary still holds under case folding.
    try std.testing.expect(!try pathIsWithin(a, "WEBBY", "web"));
}

test "packageExport: refuses a file --output (and leaves it intact)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(base);

    // A fake web build output with a shell.
    try tmp.dir.createDirPath(io, "web");
    try tmp.dir.writeFile(io, .{ .sub_path = "web/game.html", .data = "<html>g</html>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "web/game.wasm", .data = "\x00asm" });
    const web_dir = try std.fs.path.join(alloc, &.{ base, "web" });
    defer alloc.free(web_dir);

    // `--output` names an existing regular file.
    try tmp.dir.writeFile(io, .{ .sub_path = "out_is_file", .data = "keep me" });
    const out_file = try std.fs.path.join(alloc, &.{ base, "out_is_file" });
    defer alloc.free(out_file);

    try std.testing.expectError(
        error.DestructiveOutputPath,
        packageExport(alloc, web_dir, null, .{ .output_dir = out_file }),
    );
    // The file must survive (not wiped + replaced by a dir).
    try std.testing.expect(fileExists(io, out_file));
    const st = try std.Io.Dir.cwd().statFile(io, out_file, .{});
    try std.testing.expect(st.kind != .directory);
}

test "ensureIndexHtml: package default works without emitted HTML" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(base);

    // web_dir has no game.html; output dir has no index.html.
    try tmp.dir.createDirPath(io, "web");
    try tmp.dir.writeFile(io, .{ .sub_path = "web/game.wasm", .data = "\x00asm" });
    try tmp.dir.createDirPath(io, "out");
    const web_dir = try std.fs.path.join(alloc, &.{ base, "web" });
    defer alloc.free(web_dir);
    const out_dir = try std.fs.path.join(alloc, &.{ base, "out" });
    defer alloc.free(out_dir);

    var files: std.ArrayList(FileReport) = .empty;
    defer {
        for (files.items) |f| alloc.free(f.rel);
        files.deinit(alloc);
    }

    try ensureIndexHtml(alloc, io, web_dir, null, out_dir, &files);
    try std.testing.expect(files.items.len == 3);
}

test "copyTree: mirrors a nested web dir" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    try src.dir.writeFile(io, .{ .sub_path = "game.wasm", .data = "\x00asm" });
    try src.dir.writeFile(io, .{ .sub_path = "game.js", .data = "var x=1;" });
    try src.dir.createDirPath(io, "assets");
    try src.dir.writeFile(io, .{ .sub_path = "assets/atlas.png", .data = "PNGDATA" });

    const src_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &src.sub_path });
    defer alloc.free(src_dir);

    var dst = std.testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &dst.sub_path, "out" });
    defer alloc.free(dst_dir);

    var files: std.ArrayList(FileReport) = .empty;
    defer {
        for (files.items) |f| alloc.free(f.rel);
        files.deinit(alloc);
    }
    try copyTree(alloc, io, src_dir, dst_dir, &files);

    try std.testing.expectEqual(@as(usize, 3), files.items.len);
    // Nested file was copied with its subdir preserved.
    const nested = try std.fs.path.join(alloc, &.{ dst_dir, "assets", "atlas.png" });
    defer alloc.free(nested);
    try std.testing.expect(fileExists(io, nested));
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
