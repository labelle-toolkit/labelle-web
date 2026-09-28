//! Path and small file helpers shared by the export modules.
const std = @import("std");
const builtin = @import("builtin");

/// Path-boundary equality, case-insensitive on Windows (whose
/// filesystems are case-insensitive).
pub fn pathEql(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(a, b)
    else
        std.mem.eql(u8, a, b);
}

/// Strip trailing path separators (keeping at least one char) so a value
/// like `release/` yields `release` before a suffix is appended.
/// `isSep` is platform-aware: on Windows both `/` and `\` are stripped;
/// on POSIX only `/` (a `\` there is a legitimate filename byte).
pub fn trimTrailingSeps(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and std.fs.path.isSep(path[end - 1])) end -= 1;
    return path[0..end];
}

/// True when `inner` is `outer` or nested under it. Both are normalized
/// (`resolve` collapses `.`/`..` and unifies separators to the platform's
/// own) so `a/b/../out` vs `a/out`, and mixed `/`+`\` on Windows, compare
/// correctly. Paths are compared as-passed (both cwd-relative here), so
/// no filesystem access is needed.
pub fn pathIsWithin(allocator: std.mem.Allocator, inner_raw: []const u8, outer_raw: []const u8) !bool {
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

pub fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn fileSize(io: std.Io, path: []const u8) u64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.size;
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
