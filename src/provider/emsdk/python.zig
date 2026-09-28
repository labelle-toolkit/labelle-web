//! The Python 3 interpreter emsdk and emcc need.
const std = @import("std");
const emsdk = @import("../emsdk.zig");
const is_windows = emsdk.is_windows;
const Runner = emsdk.Runner;
const testing = std.testing;
const Fake = @import("test_support.zig").Fake;

/// The outcome of looking for the interpreter emsdk and emcc will run.
pub const PythonCheck = union(enum) {
    /// A command that runs Python 3.
    found: []const u8,
    /// The first command that ran was Python 2 (and no Python 3 was found).
    python2: []const u8,
    missing,
};

/// Look for Python 3: `python3` on POSIX (the launcher's and emcc's
/// interpreter), `python` then `python3` on Windows. Each candidate runs
/// `import sys; print(sys.version_info[0])`, which answers on Python 2 and 3
/// alike and fails on the Windows Store stub; only `3` is accepted.
pub fn checkPython(a: std.mem.Allocator, io: std.Io, runner: Runner) PythonCheck {
    const candidates: []const []const u8 = if (is_windows) &.{ "python", "python3" } else &.{"python3"};
    var old: ?[]const u8 = null;
    for (candidates) |cmd| {
        const out = (runner.capture(runner.ctx, io, a, &.{ cmd, "-c", "import sys; print(sys.version_info[0])" }, null) catch null) orelse continue;
        defer a.free(out);
        const major = std.mem.trim(u8, out, " \t\r\n");
        if (std.mem.eql(u8, major, "3")) return .{ .found = cmd };
        if (old == null) old = cmd;
    }
    return if (old) |cmd| .{ .python2 = cmd } else .missing;
}

pub fn findPython(a: std.mem.Allocator, io: std.Io, runner: Runner) ?[]const u8 {
    return switch (checkPython(a, io, runner)) {
        .found => |cmd| cmd,
        else => null,
    };
}

pub const python2_found =
    "labelle-web: `{s}` is Python 2, and emsdk and emcc need Python 3.\n" ++
    "  fix: run `labelle install python` (the CLI puts its managed Python on PATH),\n" ++
    "  or install Python 3 and put it first on PATH.\n";

pub const python_missing =
    "labelle-web: emsdk and emcc need Python 3, and none was found on PATH.\n" ++
    "  fix: run `labelle install python` (the CLI puts its managed Python on PATH),\n" ++
    "  or install Python 3 yourself and put `python3` on PATH.\n";

test "checkPython accepts only Python 3" {
    var fake: Fake = .{ .python_major = "2" };
    const got = checkPython(testing.allocator, testing.io, fake.runner());
    try testing.expect(got == .python2);
    try testing.expectEqual(@as(?[]const u8, null), findPython(testing.allocator, testing.io, fake.runner()));
    fake.python_major = "3";
    try testing.expect(checkPython(testing.allocator, testing.io, fake.runner()) == .found);
}

test "findPython reports a missing interpreter" {
    var fake: Fake = .{ .has_python = false };
    try testing.expectEqual(@as(?[]const u8, null), findPython(testing.allocator, testing.io, fake.runner()));
    fake.has_python = true;
    try testing.expect(findPython(testing.allocator, testing.io, fake.runner()) != null);
}
