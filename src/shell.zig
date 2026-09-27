//! Stage the browser shell after wasm optimization, before compression/serving.
//! The web provider can call this same API for exports and local builds.
const std = @import("std");

pub const template = @embedFile("shell/index.html");
pub const loader = @embedFile("shell/loader.js");
pub const logo = @embedFile("shell/logo.png");
pub const size_placeholder = "__WASM_BYTES__";
const generated_marker = "<!-- labelle-web default shell -->";

pub const Source = enum { project, emitted, default };
pub const Result = struct { source: Source, wasm_bytes: ?u64 };

/// `output` already contains game.js/game.wasm. A project's web/index.html
/// wins over an emitted index.html; otherwise use the package's default.
/// Does not copy or delete other project/build files. Caller stages custom
/// page assets separately. Reserves labelle-loader.js and labelle-logo.png.
/// Missing game.wasm gives an indeterminate loader (useful before a build).
/// Call AFTER wasm-opt/other byte-changing transforms, BEFORE precompression.
pub fn stage(allocator: std.mem.Allocator, io: std.Io, output: std.Io.Dir, project_web: ?std.Io.Dir) !Result {
    const wasm_bytes: ?u64 = if (output.statFile(io, "game.wasm", .{})) |stat| blk: {
        if (stat.kind != .file) return error.InvalidWasmFile;
        break :blk stat.size;
    } else |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var source: Source = .default;
    var owned: ?[]u8 = null;
    defer if (owned) |bytes| allocator.free(bytes);
    if (project_web) |dir| {
        owned = try readOptional(allocator, io, dir, "index.html");
        if (owned != null) source = .project;
    }
    if (owned == null) {
        owned = try readOptional(allocator, io, output, "index.html");
        if (owned) |bytes| {
            if (std.mem.startsWith(u8, bytes, "<!doctype html>\n" ++ generated_marker)) {
                allocator.free(bytes);
                owned = null; // Re-render our own page on rebuild to update its size.
            } else source = .emitted;
        }
    }
    const size = try std.fmt.allocPrint(allocator, "{d}", .{wasm_bytes orelse 0});
    defer allocator.free(size);
    const html = try std.mem.replaceOwned(u8, allocator, owned orelse template, size_placeholder, size);
    defer allocator.free(html);
    // Stage resources first: never publish a page whose package assets are missing.
    try output.writeFile(io, .{ .sub_path = "labelle-loader.js", .data = loader });
    try output.writeFile(io, .{ .sub_path = "labelle-logo.png", .data = logo });
    try output.writeFile(io, .{ .sub_path = "index.html", .data = html });
    return .{ .source = source, .wasm_bytes = wasm_bytes };
}

fn readOptional(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !?[]u8 {
    return dir.readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

test "fresh export stamps actual raw wasm bytes and ships all shell assets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "game.wasm", .data = "12345678" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game.html", .data = "emcc chrome" });
    const result = try stage(std.testing.allocator, io, tmp.dir, null);
    try std.testing.expectEqual(Source.default, result.source);
    try std.testing.expectEqual(@as(?u64, 8), result.wasm_bytes);
    const html = try tmp.dir.readFileAlloc(io, "index.html", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-wasm-bytes=\"8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, size_placeholder) == null);
    try std.testing.expectEqual(logo.len, (try tmp.dir.statFile(io, "labelle-logo.png", .{})).size);
    try std.testing.expectEqual(loader.len, (try tmp.dir.statFile(io, "labelle-loader.js", .{})).size);
}

test "project page wins and opt-in size placeholder is stamped without changing source" {
    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    const io = std.testing.io;
    const custom = "custom __WASM_BYTES__ / __WASM_BYTES__";
    try project.dir.writeFile(io, .{ .sub_path = "index.html", .data = custom });
    try out.dir.writeFile(io, .{ .sub_path = "index.html", .data = "emitted" });
    try out.dir.writeFile(io, .{ .sub_path = "game.wasm", .data = "abcd" });
    try std.testing.expectEqual(Source.project, (try stage(std.testing.allocator, io, out.dir, project.dir)).source);
    const rendered = try out.dir.readFileAlloc(io, "index.html", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("custom 4 / 4", rendered);
    const original = try project.dir.readFileAlloc(io, "index.html", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings(custom, original);
}

test "emitted custom page is preserved; absent project page falls through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "custom page" });
    const result = try stage(std.testing.allocator, io, tmp.dir, project.dir);
    try std.testing.expectEqual(Source.emitted, result.source);
    try std.testing.expectEqual(@as(?u64, null), result.wasm_bytes);
    const html = try tmp.dir.readFileAlloc(io, "index.html", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("custom page", html);
}

test "default page is restamped after rebuild or optimization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    _ = try stage(std.testing.allocator, io, tmp.dir, null);
    try tmp.dir.writeFile(io, .{ .sub_path = "game.wasm", .data = "abc" });
    try std.testing.expectEqual(Source.default, (try stage(std.testing.allocator, io, tmp.dir, null)).source);
    const html = try tmp.dir.readFileAlloc(io, "index.html", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-wasm-bytes=\"3\"") != null);
}

test "invalid wasm input fails before changing existing page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "game.wasm", .default_dir);
    try std.testing.expectError(error.InvalidWasmFile, stage(std.testing.allocator, std.testing.io, tmp.dir, null));
}
