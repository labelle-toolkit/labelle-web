/// Static file server extracted from labelle-cli at 5eccdbc. Rebuilds and
/// file watching belong to the CLI (`labelle run --watch`); this server only
/// serves the published output and reloads browsers (`watch.zig`).
/// Minimal static file server for serving WASM builds locally.
/// Serves files from `web_dir` on 127.0.0.1:`port`, opens the default
/// browser, and runs until the process is interrupted (Ctrl+C).
///
/// Single-threaded, one connection at a time — a dev-only serve loop
/// for a single browser tab, not a production server. Built directly
/// on `std.Io.net.Server` (socket) + `std.http.Server` (HTTP/1.1) so
/// the CLI keeps a zero-dependency graph.
///
/// This file holds the serve loop and its entry point; `serve/` holds the
/// parts: `stop.zig` (graceful stop and deadline), `route.zig` (MIME types
/// and target → path), `request.zig` (one HTTP request) and `inject.zig`
/// (the run-options and live-reload scripts spliced into HTML).
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const watch = @import("watch.zig");
const stop_mod = @import("serve/stop.zig");
const route_mod = @import("serve/route.zig");
const inject_mod = @import("serve/inject.zig");
const request_mod = @import("serve/request.zig");
const deadlineLoop = stop_mod.deadlineLoop;
const wakeListener = stop_mod.wakeListener;
const wakeLoop = stop_mod.wakeLoop;
const handleConnection = request_mod.handleConnection;
const testBindFreePort = @import("serve/test_support.zig").testBindFreePort;
pub const installCancelHandler = stop_mod.installCancelHandler;
pub const runEnvScript = inject_mod.runEnvScript;
pub const RunEnv = inject_mod.RunEnv;

/// Set once a stop was asked for; the serve loop returns when it sees it.
pub var cancel_requested: std.atomic.Value(bool) = .init(false);

/// The accept loop. Returns once `cancel` is set — before handling any
/// connection accepted after the request, so the wake-up poke (or a real
/// request racing it) is closed unanswered. Per-connection errors never
/// end the loop.
fn serveLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: *std.Io.net.Server,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    watch_state: ?*WatchState,
    cancel: *const std.atomic.Value(bool),
) void {
    while (!cancel.load(.acquire)) {
        const stream = server.accept(io) catch |err| {
            // Transient accept failures (e.g. the peer reset between
            // the SYN and our accept) shouldn't take the server down.
            std.debug.print("labelle-web: accept failed ({s}), continuing\n", .{@errorName(err)});
            continue;
        };
        if (cancel.load(.acquire)) {
            stream.close(io);
            return;
        }
        handleConnection(io, allocator, stream, web_dir, project_web_dir, watch_state, cancel) catch |err| {
            std.debug.print("labelle-web: connection error ({s})\n", .{@errorName(err)});
        };
    }
}

/// Serve static files from `web_dir` on 127.0.0.1:`port`, then open the
/// browser. Blocks until a stop is asked for (Ctrl+C / SIGTERM; see
/// `installCancelHandler`), then returns cleanly so the caller can run
/// what follows the serve — or returns early on a bind failure. The
/// accept loop swallows per-connection errors so a flaky tab can't kill
/// the server.
///
/// `web_dir` is the build output dir (`.labelle/<backend>_wasm/zig-out/web`).
/// `project_web_dir` is the durable project shell dir (`<project>/web`);
/// if it holds an `index.html`, that file is served at `/` so the user
/// gets a clean root page instead of emcc's chrome-heavy `game.html`.
/// Pass `null` to disable the project-shell lookup.
///
/// `open_browser` controls the auto-launch — `labelle wasm serve
/// --no-open` passes `false` to suppress it.
///
/// `session` is the `run.watch` object of a `labelle run --watch`
/// replacement. With it every request is served from the published
/// `session.output_dir` (`web_dir` is then only the banner's label), a
/// poller thread follows `session.generation_file`, and connected browsers
/// reload through an injected client polling `/__labelle_livereload`.
/// Pass `null` for a plain static serve.
///
/// Returns how the serve ended: `.timed_out` when the `timeout_ms`
/// deadline stopped it, `.stopped` for any other stop request.
pub fn serveAndOpen(
    allocator: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    port: u16,
    open_browser_tab: bool,
    session: ?watch.Session,
    run_env: []const RunEnv,
    timeout_ms: ?u64,
) !Ending {
    const io = config.globalIo();

    // The session starts at the generation the CLI published before it
    // launched this replacement (0), read before the first request.
    const env_script = try runEnvScript(allocator, run_env);
    defer if (env_script) |e| allocator.free(e);
    var wstate = WatchState{ .session = session, .run_env_script = env_script };
    if (session) |s| {
        const initial = (try watch.readGeneration(io, s.generation_file)) orelse return error.MissingWatchGeneration;
        wstate.version.store(initial, .release);
    }

    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print(
            "labelle-web: could not bind 127.0.0.1:{d} ({s}).\n" ++
                "  Another server may already be on that port; pass a different --port.\n",
            .{ port, @errorName(err) },
        );
        return err;
    };
    defer server.deinit(io);

    // The stop handler and its waker come first, so a Ctrl+C at any point
    // after the bind ends the loop instead of the process. `wstate.stop`
    // also ends the waker if the loop is left some other way.
    installCancelHandler();
    const waker: ?std.Thread = std.Thread.spawn(.{}, wakeLoop, .{ io, port, &cancel_requested, &wstate.stop }) catch |err| blk: {
        std.debug.print("labelle-web: could not start the stop watcher ({s}); Ctrl+C ends the process without after-run hooks\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (waker) |t| {
        wstate.stop.store(true, .release);
        t.join();
    };
    // A deadline without its thread would serve forever: fail instead.
    var deadline_fired: std.atomic.Value(bool) = .init(false);
    const deadline: ?std.Thread = if (timeout_ms) |ms| try std.Thread.spawn(.{}, deadlineLoop, .{ io, ms, &cancel_requested, &wstate.stop, &deadline_fired }) else null;
    defer if (deadline) |t| {
        wstate.stop.store(true, .release);
        t.join();
    };

    // A watch session without its poller would never reload: fail instead.
    const poller: ?std.Thread = if (session) |s| try std.Thread.spawn(.{}, watch.pollLoop, .{ io, s, &wstate, @as(u32, 200) }) else null;
    defer if (poller) |t| {
        wstate.stop.store(true, .release);
        t.join();
    };
    const watch_state: ?*WatchState = if (session != null or env_script != null) &wstate else null;

    std.debug.print(
        "labelle-web: serving {s}\n" ++
            "  Local:   http://127.0.0.1:{d}\n" ++
            "{s}" ++
            "  Press Ctrl+C to stop\n",
        .{
            if (session) |s| s.output_dir else web_dir,
            port,
            if (session != null) "  Watch session: labelle rebuilds on change; this page reloads after each successful build\n" else "",
        },
    );

    if (open_browser_tab) openBrowser(allocator, port);

    serveLoop(io, allocator, &server, web_dir, project_web_dir, watch_state, &cancel_requested);
    std.debug.print("\nlabelle-web: stopping server\n", .{});
    return if (deadline_fired.load(.acquire)) .timed_out else .stopped;
}

/// How `serveAndOpen` ended.
pub const Ending = enum {
    /// A stop request (Ctrl+C / SIGTERM) ended the serve.
    stopped,
    /// The `labelle run --timeout` deadline (`run.timeout_ms`) ended it.
    timed_out,
};

/// Best-effort browser launch. A failure here is non-fatal — the
/// server is already up and the URL is printed; the user can open it
/// by hand.
fn openBrowser(allocator: std.mem.Allocator, port: u16) void {
    const io = config.globalIo();
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port}) catch return;
    defer allocator.free(url);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch return;
}

/// Shared between the generation poller and the serve loop (`watch.zig`).
const WatchState = watch.State;

// ── Tests ───────────────────────────────────────────────────────────

// Every submodule is analyzed (and its tests run) wherever this file's tests are.
test {
    _ = stop_mod;
    _ = route_mod;
    _ = inject_mod;
    _ = request_mod;
}

// A stop request ends the accept loop — the path that makes the `after run`
// hooks after `serveAndOpen` reachable (Codex P2 on #420). The signal /
// console handler itself is interactive and is not driven here; the flag
// it sets and the waker's poke are.
test "serveLoop: returns on a stop request after serving what came before it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(web_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "stop_test.html", .data = "<h1>still here</h1>" });

    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    defer server.deinit(io);
    var cancel: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, serveLoop, .{ io, alloc, &server, web_dir, @as(?[]const u8, null), @as(?*WatchState, null), &cancel });

    // A request ahead of the stop is answered in full.
    const peer = std.Io.net.IpAddress.parse("127.0.0.1", bound.port) catch unreachable;
    {
        const s = try peer.connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [256]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.print("GET /stop_test.html HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{});
        try w.interface.flush();
        var rbuf: [4096]u8 = undefined;
        var r = s.reader(io, &rbuf);
        const response = try r.interface.allocRemaining(alloc, .unlimited);
        defer alloc.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "still here") != null);
    }

    // An incomplete request must not trap the server in receiveHead.
    const stalled = try peer.connect(io, .{ .mode = .stream });
    defer stalled.close(io);
    var partial_buf: [128]u8 = undefined;
    var partial = stalled.writer(io, &partial_buf);
    try partial.interface.writeAll("GET / HTTP/1.1\r\nHost:");
    try partial.interface.flush();
    try io.sleep(std.Io.Duration.fromMilliseconds(100), .awake);

    // The stop: flag, then the same poke the waker thread sends. The join
    // completes only because the loop saw the flag — a loop that ignored it
    // would answer the poke, block in the next accept and never return.
    cancel.store(true, .release);
    wakeListener(io, bound.port);
    t.join();

    // Once set, the loop does not accept at all: a direct call returns
    // without touching the listener (nobody connects here).
    serveLoop(io, alloc, &server, web_dir, null, null, &cancel);
}

test "serveAndOpen: a run timeout stops the server cleanly at the deadline" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var probe = bound.server;
    probe.deinit(io);
    defer cancel_requested.store(false, .release);
    cancel_requested.store(false, .release);
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    // Returns (no error) only because the deadline asked for the stop, and
    // says so.
    try std.testing.expectEqual(Ending.timed_out, try serveAndOpen(std.testing.allocator, root, null, bound.port, false, null, &.{}, 300));
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
    try std.testing.expect(cancel_requested.load(.acquire));
    try std.testing.expect(elapsed >= 300);
    try std.testing.expect(elapsed < 10_000);
}
