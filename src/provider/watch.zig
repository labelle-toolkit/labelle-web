//! Browser watch sessions: the provider half of `labelle run --watch`
//! (contract 1.3.0 `run.watch`, RFC labelle-cli#466 §3.4).
//!
//! The CLI owns watching, rebuilding and publication: after a rebuild has
//! fully succeeded it copies the staged tree into a fresh published
//! directory, switches `run.watch.output_dir` (a symlink, or a junction on
//! Windows) to it, and only then advances `run.watch.generation_file`. A
//! failed rebuild publishes nothing. This module is what the provider does
//! with that: it polls the generation file and, when the number changes,
//! bumps the version the injected browser client polls, so every open tab
//! reloads onto the new, complete generation. Requests never read the
//! staging tree: the server resolves `output_dir` afresh for every request
//! and serves that request from the one published directory it resolved to.
const std = @import("std");

/// The `run.watch` object of the replacement's context.
pub const Session = struct {
    generation_file: []const u8,
    output_dir: []const u8,
};

/// Shared between the poller thread and the serve loop. `version` is the
/// last generation seen (what the browser client polls); `stop` ends the
/// poller; `session` is non-null in a watch session.
pub const State = struct {
    version: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    session: ?Session = null,
    /// `serve.runEnvScript`: the `labelle run` options for served pages.
    run_env_script: ?[]const u8 = null,
    /// Serve cross-origin isolated (COOP `same-origin` + COEP `require-corp`):
    /// a threaded build (`"threads": true`, labelle-web#24) can't start
    /// without it. Off otherwise, since COEP blocks cross-origin resources
    /// a plain page may load.
    isolate: bool = false,
};

/// The generation number in `path`: ASCII decimal digits and an optional
/// trailing newline. Null when the file does not exist yet.
pub fn readGeneration(io: std.Io, path: []const u8) !?u64 {
    var buf: [64]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const n = try reader.interface.readSliceShort(&buf);
    return try parseGeneration(buf[0..n]);
}

pub fn parseGeneration(bytes: []const u8) !u64 {
    const text = std.mem.trimEnd(u8, bytes, "\r\n");
    if (text.len == 0) return error.InvalidGeneration;
    for (text) |c| if (c < '0' or c > '9') return error.InvalidGeneration;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidGeneration;
}

/// One poll: read the generation and, when it differs from the one
/// `state` holds, publish it there. Returns the new generation on a
/// change, null otherwise. An unreadable or malformed file (the CLI
/// replaces it by rename, so a reader never sees a torn write) is not a
/// change: the last good generation keeps being served.
pub fn pollOnce(io: std.Io, session: Session, state: *State) ?u64 {
    const seen = (readGeneration(io, session.generation_file) catch return null) orelse return null;
    if (seen == state.version.load(.acquire)) return null;
    state.version.store(seen, .release);
    return seen;
}

/// Poller thread body: poll every `interval_ms` until `state.stop`.
pub fn pollLoop(io: std.Io, session: Session, state: *State, interval_ms: u32) void {
    const interval = std.Io.Duration.fromMilliseconds(interval_ms);
    while (!state.stop.load(.acquire)) {
        io.sleep(interval, .awake) catch return;
        if (pollOnce(io, session, state)) |generation| {
            std.debug.print("labelle-web: generation {d} published; reloading browsers\n", .{generation});
        }
    }
}

/// The directory a watch-session request is served from: the published
/// output's `web/` as `output_dir` names it right now, resolved once for
/// the request so every path check and read of that request sees the same
/// generation. Never cached across requests: the CLI switches `output_dir`
/// to each new publication. Caller owns the result.
pub fn servedRoot(a: std.mem.Allocator, io: std.Io, session: Session) ![:0]u8 {
    const web = try std.fs.path.join(a, &.{ session.output_dir, "web" });
    defer a.free(web);
    return std.Io.Dir.cwd().realPathFileAlloc(io, web, a);
}

test "parseGeneration accepts a decimal line and rejects everything else" {
    try std.testing.expectEqual(@as(u64, 0), try parseGeneration("0\n"));
    try std.testing.expectEqual(@as(u64, 12), try parseGeneration("12"));
    try std.testing.expectEqual(@as(u64, 7), try parseGeneration("7\r\n"));
    for ([_][]const u8{ "", "\n", "-1\n", "1 2\n", "x\n", "99999999999999999999999\n" }) |bad| {
        try std.testing.expectError(error.InvalidGeneration, parseGeneration(bad));
    }
}

test "pollOnce reports a new generation once, keeps the last good one on a bad write" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const gen = try std.fs.path.join(a, &.{ root, "generation" });
    defer a.free(gen);
    const session: Session = .{ .generation_file = gen, .output_dir = root };
    var state: State = .{ .session = session };

    // Before the first publication there is nothing to report.
    try std.testing.expectEqual(@as(?u64, null), pollOnce(io, session, &state));
    try tmp.dir.writeFile(io, .{ .sub_path = "generation", .data = "0\n" });
    try std.testing.expectEqual(@as(?u64, null), pollOnce(io, session, &state));
    try tmp.dir.writeFile(io, .{ .sub_path = "generation", .data = "1\n" });
    try std.testing.expectEqual(@as(?u64, 1), pollOnce(io, session, &state));
    try std.testing.expectEqual(@as(u64, 1), state.version.load(.acquire));
    // The same generation again is not a change: no second reload.
    try std.testing.expectEqual(@as(?u64, null), pollOnce(io, session, &state));
    // A malformed file is not a publication: the last good one stands.
    try tmp.dir.writeFile(io, .{ .sub_path = "generation", .data = "garbage" });
    try std.testing.expectEqual(@as(?u64, null), pollOnce(io, session, &state));
    try std.testing.expectEqual(@as(u64, 1), state.version.load(.acquire));
    try tmp.dir.writeFile(io, .{ .sub_path = "generation", .data = "2\n" });
    try std.testing.expectEqual(@as(?u64, 2), pollOnce(io, session, &state));
}

test "servedRoot follows output_dir to the publication it names now" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // symlinks need a privilege; the e2e covers junctions
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try tmp.dir.createDirPath(io, "published-0/web");
    try tmp.dir.createDirPath(io, "published-1/web");
    try tmp.dir.symLink(io, "published-0", "current", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const current = try std.fs.path.join(a, &.{ root, "current" });
    defer a.free(current);
    const session: Session = .{ .generation_file = current, .output_dir = current };

    const first = try servedRoot(a, io, session);
    defer a.free(first);
    try std.testing.expect(std.mem.endsWith(u8, first, "published-0" ++ std.fs.path.sep_str ++ "web"));
    // The CLI renames a new link over the old one; the next request follows it.
    try tmp.dir.symLink(io, "published-1", "next", .{ .is_directory = true });
    try tmp.dir.rename("next", tmp.dir, "current", io);
    const second = try servedRoot(a, io, session);
    defer a.free(second);
    try std.testing.expect(std.mem.endsWith(u8, second, "published-1" ++ std.fs.path.sep_str ++ "web"));
}
