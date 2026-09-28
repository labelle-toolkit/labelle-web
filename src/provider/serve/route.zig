//! Request routing helpers: the Content-Type table and the mapping from an
//! HTTP request target to a `web_dir`-relative path.
const std = @import("std");
const builtin = @import("builtin");

/// Extension → Content-Type. WASM and JS are the load-bearing ones:
/// browsers refuse to instantiate `application/wasm` served as
/// `application/octet-stream` via the streaming path, and ES modules
/// need a JS MIME type. The rest cover a typical asset bundle.
const mime_table = [_]struct { ext: []const u8, ct: []const u8 }{
    .{ .ext = ".wasm", .ct = "application/wasm" },
    .{ .ext = ".js", .ct = "text/javascript" },
    .{ .ext = ".mjs", .ct = "text/javascript" },
    .{ .ext = ".html", .ct = "text/html; charset=utf-8" },
    .{ .ext = ".css", .ct = "text/css" },
    .{ .ext = ".json", .ct = "application/json" },
    .{ .ext = ".png", .ct = "image/png" },
    .{ .ext = ".jpg", .ct = "image/jpeg" },
    .{ .ext = ".jpeg", .ct = "image/jpeg" },
    .{ .ext = ".gif", .ct = "image/gif" },
    .{ .ext = ".svg", .ct = "image/svg+xml" },
    .{ .ext = ".ico", .ct = "image/x-icon" },
    .{ .ext = ".wav", .ct = "audio/wav" },
    .{ .ext = ".ogg", .ct = "audio/ogg" },
    .{ .ext = ".ttf", .ct = "font/ttf" },
    .{ .ext = ".woff2", .ct = "font/woff2" },
};

pub fn mimeFor(path: []const u8) []const u8 {
    for (mime_table) |row| {
        if (std.ascii.endsWithIgnoreCase(path, row.ext)) return row.ct;
    }
    return "application/octet-stream";
}

/// Map an HTTP request target to a `web_dir`-relative path.
/// Returns `null` for anything that escapes the served root.
///
///   "/"            → "index.html"
///   "/game.wasm"   → "game.wasm"
///   "/a/b.js?v=1"  → "a/b.js"
///   "/../etc"      → null   (rejected)
///   "/..\\win.ini" → null   (rejected — backslash)
///   "//etc/passwd" → null   (rejected — still absolute)
fn resolveTarget(target: []const u8) ?[]const u8 {
    // Drop the query string / fragment.
    var path = target;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];

    return resolvePath(path);
}

pub fn resolvePath(raw_path: []const u8) ?[]const u8 {
    var path = raw_path;
    if (path.len == 0 or path[0] != '/') return null;

    // Reject any backslash outright. A legit web asset path never has
    // one, and on Windows '\' is a path separator — so a target like
    // "/..\..\windows\win.ini" would otherwise be a single segment
    // that dodges the '..' check below and escapes `web_dir`.
    if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, path, '\\') != null) return null;

    path = path[1..]; // strip leading '/'
    if (path.len == 0) return "index.html";

    // A second leading '/' (e.g. "//etc/passwd") would leave the path
    // absolute after the strip above and flow straight into
    // `std.fs.path.join`, escaping `web_dir`. Reject anything still
    // absolute.
    if (path[0] == '/') return null;

    // Reject traversal. A '..' segment or an embedded NUL would let a
    // request walk out of `web_dir`.
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    var it = std.mem.splitScalar(u8, path, '/');
    var first_component = true;
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return null;
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (first_component and std.ascii.eqlIgnoreCase(seg, @import("../assets.zig").state_file)) return null;
        first_component = false;
    }
    return path;
}

test "resolveTarget: hides shell provenance and path aliases" {
    try std.testing.expect(resolveTarget("/.labelle-shell-state.json") == null);
    try std.testing.expect(resolveTarget("/./.labelle-shell-state.json?cache=1") == null);
    try std.testing.expect(resolveTarget("/.LABELLE-SHELL-STATE.JSON") == null);
}

test "resolveTarget: root maps to index.html" {
    try std.testing.expectEqualStrings("index.html", resolveTarget("/").?);
}

test "resolveTarget: plain file" {
    try std.testing.expectEqualStrings("game.wasm", resolveTarget("/game.wasm").?);
}

test "resolveTarget: nested path" {
    try std.testing.expectEqualStrings("assets/atlas.png", resolveTarget("/assets/atlas.png").?);
}

test "resolveTarget: strips query string" {
    try std.testing.expectEqualStrings("game.js", resolveTarget("/game.js?v=42").?);
}

test "resolveTarget: strips fragment" {
    try std.testing.expectEqualStrings("index.html", resolveTarget("/index.html#top").?);
}

test "resolveTarget: rejects parent traversal" {
    try std.testing.expect(resolveTarget("/../etc/passwd") == null);
    try std.testing.expect(resolveTarget("/assets/../../secret") == null);
}

test "resolveTarget: backslash is a separator only on Windows" {
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqualStrings("icon\\dark.png", resolveTarget("/icon\\dark.png").?);
        return;
    }
    // On Windows '\' is a path separator, so "/..\..\win.ini" would be
    // a single segment that dodges the '..' check. Reject any '\'.
    try std.testing.expect(resolveTarget("/..\\..\\windows\\win.ini") == null);
    try std.testing.expect(resolveTarget("/assets\\atlas.png") == null);
    try std.testing.expect(resolveTarget("/a\\b") == null);
}

test "resolveTarget: rejects double-slash (still absolute)" {
    // "//etc/passwd" stays absolute after stripping one leading slash
    // and would escape web_dir via path.join.
    try std.testing.expect(resolveTarget("//etc/passwd") == null);
    try std.testing.expect(resolveTarget("///etc/passwd") == null);
}

test "resolveTarget: rejects embedded NUL" {
    try std.testing.expect(resolveTarget("/game\x00.wasm") == null);
}

test "resolveTarget: rejects target without leading slash" {
    try std.testing.expect(resolveTarget("game.wasm") == null);
    try std.testing.expect(resolveTarget("") == null);
}

test "resolveTarget: a literal '..' segment only — not a substring" {
    // "..foo" is a legitimate filename, not traversal.
    try std.testing.expectEqualStrings("..foo.txt", resolveTarget("/..foo.txt").?);
}

test "mimeFor: known extensions" {
    try std.testing.expectEqualStrings("application/wasm", mimeFor("game.wasm"));
    try std.testing.expectEqualStrings("text/javascript", mimeFor("game.js"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeFor("index.html"));
}

test "mimeFor: case-insensitive extension match" {
    try std.testing.expectEqualStrings("image/png", mimeFor("LOGO.PNG"));
}

test "mimeFor: unknown extension falls back to octet-stream" {
    try std.testing.expectEqualStrings("application/octet-stream", mimeFor("data.bin"));
}
