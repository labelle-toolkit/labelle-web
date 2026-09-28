//! Web export packaging, extracted from labelle-cli at 5eccdbc.
//! Copy, optimize, stage the branded/custom shell, then package the final bytes.
//!
//! This file drives the export; `export/` holds its parts: `ownership.zig`
//! (the export marker and archive ownership), `wasm_opt.zig` (the optimize
//! pass), `zip.zig` (the archive writer) and `paths.zig` (path helpers).
const std = @import("std");
const config = @import("config.zig");
const ownership_mod = @import("export/ownership.zig");
const wasm_opt_mod = @import("export/wasm_opt.zig");
const zip_mod = @import("export/zip.zig");
const paths_mod = @import("export/paths.zig");
const readOwnership = ownership_mod.readOwnership;
const writeOwnership = ownership_mod.writeOwnership;
const hashFile = ownership_mod.hashFile;
const checkArchiveDestination = ownership_mod.checkArchiveDestination;
const optimizeWasm = wasm_opt_mod.optimizeWasm;
const writeZipArchive = zip_mod.writeZipArchive;
const collectRelFiles = zip_mod.collectRelFiles;
const pathIsWithin = paths_mod.pathIsWithin;
const fileExists = paths_mod.fileExists;
const fileSize = paths_mod.fileSize;
pub const outputDirIsUnsafe = ownership_mod.outputDirIsUnsafe;

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
    /// A `wasm-opt` to run when none is on PATH (the emsdk's
    /// `upstream/bin` one, `emsdk.wasmOptPath`).
    wasm_opt_fallback: ?[]const u8 = null,
};

/// A packaged file and its size before/after optimization. `before` ==
/// `after` for everything except `.wasm` files that `wasm-opt` shrank.
pub const FileReport = struct {
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
    if (opts.platform == .github_pages) {
        try validatePagesMarker(allocator, io, web_dir);
        if (project_web_dir) |custom| try validatePagesMarker(allocator, io, custom);
    }

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
    const wasm_opt_ran = try optimizeWasm(allocator, io, opts.output_dir, &files, opts.wasm_opt_fallback);
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
        if (root) for ([_][]const u8{ "index.html", "labelle-loader.js", "labelle-logo.png", @import("assets.zig").state_file }) |name| {
            if (std.ascii.eqlIgnoreCase(entry.name, name) and entry.kind != .file) return error.InvalidWebAssetDestination;
        };
        switch (entry.kind) {
            .directory => try validateTree(io, dir, entry.name, false),
            .file => {},
            else => return error.UnsupportedBuildArtifact,
        }
    }
}
fn validatePagesMarker(a: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, ".nojekyll") and !std.mem.eql(u8, entry.name, ".nojekyll")) return error.InvalidPagesMarker;
    }
    const path = try std.fs.path.join(a, &.{ root, ".nojekyll" });
    defer a.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidPagesMarker;
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

// ── Tests ───────────────────────────────────────────────────────────

// Every submodule is analyzed (and its tests run) wherever this file's tests are.
test {
    _ = ownership_mod;
    _ = wasm_opt_mod;
    _ = zip_mod;
    _ = paths_mod;
}

test "parsePlatform: known + unknown" {
    try std.testing.expectEqual(Platform.itch, parsePlatform("itch").?);
    try std.testing.expectEqual(Platform.github_pages, parsePlatform("github-pages").?);
    try std.testing.expectEqual(Platform.github_pages, parsePlatform("github_pages").?);
    try std.testing.expect(parsePlatform("nope") == null);
    try std.testing.expect(parsePlatform("") == null);
}

test "formatSize: byte/KB/MB thresholds" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", formatSize(&buf, 512));
    try std.testing.expectEqualStrings("2 KB", formatSize(&buf, 2048));
    try std.testing.expectEqualStrings("1.5 MB", formatSize(&buf, 1024 * 1024 * 3 / 2));
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
