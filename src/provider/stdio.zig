//! The provider's stdout/stderr writers (labelle-cli#446) and its stdout
//! discipline (contract §2, RFC labelle-cli#466 §8).
//!
//! `labelle build > log 2>&1` hands the CLI and this tool ONE open file
//! description, so both must append at its shared offset. Zig 0.16's
//! `File.writer` is positional: it pwrite()s at an offset it tracks itself,
//! starting from 0, so on a redirected file it overwrites whatever the CLI
//! already wrote. Every stdout/stderr writer here is streaming.
//!
//! Under `--progress=json` the CLI's stdout carries only its NDJSON feed,
//! and a provider inherits that stdout. Diagnostics therefore always go to
//! stderr (`std.debug.print`); `answer` is the one place a command's result
//! reaches stdout, and only outside JSON progress. A child process the
//! provider spawns (git, emsdk) gets stderr as its stdout (`child_stdout`).
const std = @import("std");

pub fn stdoutWriter(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(io, buffer);
}

pub fn stderrWriter(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(io, buffer);
}

/// Where a spawned child's stdout goes: the provider's stderr, never the
/// stdout the CLI's progress feed may own.
pub fn childStdout() std.process.SpawnOptions.StdIo {
    return .{ .file = std.Io.File.stderr() };
}

/// A command's human-readable answer (`toolchain which`, ...): stdout, or
/// stderr when the CLI's stdout carries JSON progress.
pub fn answer(io: std.Io, json_progress: bool, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = if (json_progress) stderrWriter(io, &buf) else stdoutWriter(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

/// One machine-readable document on stdout (`doctor --json`).
pub fn json(io: std.Io, value: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(io, &buf);
    try std.json.Stringify.value(value, .{}, &w.interface);
    try w.interface.writeByte('\n');
    try w.interface.flush();
}

test "streaming appends at the shared offset instead of overwriting from 0" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "redirected.txt", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "cli: first line\n");
    var buf: [16]u8 = undefined;
    var w = file.writerStreaming(io, &buf);
    try w.interface.writeAll("tool: a line longer than the buffer\n");
    try w.interface.flush();
    try file.writeStreamingAll(io, "cli: last line\n");
    const got = try tmp.dir.readFileAlloc(io, "redirected.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("cli: first line\ntool: a line longer than the buffer\ncli: last line\n", got);
}
