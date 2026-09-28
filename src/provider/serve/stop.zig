//! Graceful stop: the Ctrl+C / SIGTERM (console control on Windows)
//! handler, the waker that pokes a blocked `accept`, and the run deadline.
const std = @import("std");
const builtin = @import("builtin");
const serve = @import("../serve.zig");
/// The process-wide stop flag lives in `serve.zig`; this is a pointer to it.
const cancel_requested = &serve.cancel_requested;
const testBindFreePort = @import("test_support.zig").testBindFreePort;

// ── Graceful stop (Codex P2 on #420) ────────────────────────────────
//
// The serve loop used to block until the process died: Ctrl+C killed
// labelle outright, so the pipeline code after `serveAndOpen` — the
// `after run` provider hooks — was unreachable. Now Ctrl+C / SIGTERM
// (POSIX) or a console Ctrl+C / Ctrl+Break / close (Windows) sets
// `cancel_requested`, a waker thread pokes the listener with one loopback
// connection so a blocked `accept` returns, the loop observes the flag and
// returns cleanly, and the caller runs its hooks and exits. A second
// Ctrl+C while a hook is still running forces the exit (POSIX: status
// 130; Windows: the console's default handling).
//
// The wake goes through a connection rather than `poll` or a socket
// shutdown because it is the one mechanism that behaves the same on every
// platform `std.Io.net` supports (`std.posix.poll` is a compile error on
// Windows, and a shutdown of a listening socket wakes `accept` on Linux
// but not on macOS) and needs nothing in a signal handler beyond an atomic
// store. Windows Ctrl+C handling is best-effort: the handler is registered
// with `SetConsoleCtrlHandler`, but CI cannot exercise a console control
// event, so it is compile-checked only.

/// Register the stop handler for this process. Idempotent.
pub fn installCancelHandler() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(consoleCtrl, .TRUE);
    } else {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }
}

/// Async-signal-safe: one atomic swap, and `_exit` on the repeat.
fn onSignal(_: std.posix.SIG) callconv(.c) void {
    if (cancel_requested.swap(true, .acq_rel)) std.c._exit(130);
}

const HandlerRoutine = *const fn (ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HandlerRoutine, add: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;

/// Runs on a console-owned thread. Returning TRUE claims the event; the
/// repeat returns FALSE so the console's default handling ends the process.
fn consoleCtrl(_: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    return if (cancel_requested.swap(true, .acq_rel)) .FALSE else .TRUE;
}

/// Open and close one loopback connection so a blocked `accept` returns
/// and the loop can look at its flag. Failure is harmless: the next real
/// request wakes the loop the same way.
pub fn wakeListener(io: std.Io, port: u16) void {
    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const s = peer.connect(io, .{ .mode = .stream }) catch return;
    s.close(io);
}

/// Waker thread body: watch `cancel` and, once it is set, poke the
/// listener. `stop` ends the thread without a poke when the loop is
/// already gone.
pub fn wakeLoop(io: std.Io, port: u16, cancel: *const std.atomic.Value(bool), stop: *const std.atomic.Value(bool)) void {
    const tick = std.Io.Duration.fromMilliseconds(100);
    while (!stop.load(.acquire)) {
        if (cancel.load(.acquire)) {
            wakeListener(io, port);
            return;
        }
        io.sleep(tick, .awake) catch return;
    }
}

/// Deadline thread body (`labelle run --timeout`, `run.timeout_ms`): once
/// `ms` have passed, ask for the same clean stop Ctrl+C asks for, so the
/// server returns and the provider exits 0. `fired` is set only when the
/// deadline claimed that stop itself: a Ctrl+C / SIGTERM that asked first,
/// even during the last tick, leaves it unset. Read it after joining this
/// thread. `stop` ends it early.
pub fn deadlineLoop(io: std.Io, ms: u64, cancel: *std.atomic.Value(bool), stop: *const std.atomic.Value(bool), fired: *std.atomic.Value(bool)) void {
    const tick: u64 = 20;
    var waited: u64 = 0;
    while (waited < ms) {
        if (stop.load(.acquire) or cancel.load(.acquire)) return;
        const step = @min(tick, ms - waited);
        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(step)), .awake) catch return;
        waited += step;
    }
    if (stop.load(.acquire)) return;
    std.debug.print("labelle-web: run timeout ({d} ms) reached; stopping the server\n", .{ms});
    // Claim the stop atomically: if a signal already asked for it, the
    // signal ended the serve, not the deadline.
    if (cancel.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    fired.store(true, .release);
}

test "deadlineLoop: sets the stop flag after the deadline, not when stopped first" {
    const io = std.testing.io;
    var cancel: std.atomic.Value(bool) = .init(false);
    var stop: std.atomic.Value(bool) = .init(true);
    var fired: std.atomic.Value(bool) = .init(false);
    deadlineLoop(io, 10_000, &cancel, &stop, &fired);
    try std.testing.expect(!cancel.load(.acquire) and !fired.load(.acquire));
    stop.store(false, .release);
    deadlineLoop(io, 30, &cancel, &stop, &fired);
    try std.testing.expect(cancel.load(.acquire) and fired.load(.acquire));
}

test "deadlineLoop: a stop a signal already asked for is not claimed as the deadline's" {
    const io = std.testing.io;
    var stop: std.atomic.Value(bool) = .init(false);
    var fired: std.atomic.Value(bool) = .init(false);
    // A zero deadline goes straight to the claim, which a signal that set
    // `cancel` first wins (the last-tick race, made deterministic).
    var cancel: std.atomic.Value(bool) = .init(true);
    deadlineLoop(io, 0, &cancel, &stop, &fired);
    try std.testing.expect(cancel.load(.acquire) and !fired.load(.acquire));
    // Unclaimed, the same zero deadline claims it and fires.
    cancel.store(false, .release);
    deadlineLoop(io, 0, &cancel, &stop, &fired);
    try std.testing.expect(cancel.load(.acquire) and fired.load(.acquire));
}

test "wakeLoop: pokes the listener once the flag is set and ends on stop without one" {
    const io = std.testing.io;
    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    defer server.deinit(io);
    var cancel: std.atomic.Value(bool) = .init(false);
    var stop: std.atomic.Value(bool) = .init(false);
    // Stop first: the waker must end without connecting.
    stop.store(true, .release);
    wakeLoop(io, bound.port, &cancel, &stop);
    stop.store(false, .release);
    // Cancel: the waker's poke is what `accept` returns with.
    cancel.store(true, .release);
    const t = try std.Thread.spawn(.{}, wakeLoop, .{ io, bound.port, &cancel, &stop });
    defer t.join();
    const poke = try server.accept(io);
    poke.close(io);
}
