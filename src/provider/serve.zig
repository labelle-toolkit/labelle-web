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
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const watch = @import("watch.zig");

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

fn mimeFor(path: []const u8) []const u8 {
    for (mime_table) |row| {
        if (std.ascii.endsWithIgnoreCase(path, row.ext)) return row.ct;
    }
    return "application/octet-stream";
}

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

/// Set once a stop was asked for; the serve loop returns when it sees it.
pub var cancel_requested: std.atomic.Value(bool) = .init(false);

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
fn wakeListener(io: std.Io, port: u16) void {
    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const s = peer.connect(io, .{ .mode = .stream }) catch return;
    s.close(io);
}

/// Waker thread body: watch `cancel` and, once it is set, poke the
/// listener. `stop` ends the thread without a poke when the loop is
/// already gone.
fn wakeLoop(io: std.Io, port: u16, cancel: *const std.atomic.Value(bool), stop: *const std.atomic.Value(bool)) void {
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
/// server returns and the provider exits 0. `stop` ends it early.
fn deadlineLoop(io: std.Io, ms: u64, cancel: *std.atomic.Value(bool), stop: *const std.atomic.Value(bool)) void {
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
    cancel.store(true, .release);
}

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
pub fn serveAndOpen(
    allocator: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    port: u16,
    open_browser_tab: bool,
    session: ?watch.Session,
    run_env: []const RunEnv,
    timeout_ms: ?u64,
) !void {
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
    const deadline: ?std.Thread = if (timeout_ms) |ms| try std.Thread.spawn(.{}, deadlineLoop, .{ io, ms, &cancel_requested, &wstate.stop }) else null;
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
}

/// True if `path` names a regular file that can be opened for reading.
fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// True if the request target addresses the site root — `/` or a bare
/// `/index.html` (query string / fragment already stripped by the
/// caller via `resolveTarget`, which yields `"index.html"` for both).
fn isRootRequest(rel: []const u8) bool {
    return std.mem.eql(u8, rel, "index.html");
}

/// Resolve a root (`/` or `/index.html`) request to the file that
/// should back it. Resolution order:
///   a. `<project>/web/index.html` — the clean project shell.
///   b. `<build web dir>/index.html` — a build-produced shell.
///   c. `<build web dir>/game.html` — emcc's chrome-heavy shell.
///   d. else `null` — caller answers 404.
/// Returns an allocator-owned path the caller must free.
fn resolveRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
) !?[]const u8 {
    if (project_web_dir) |pwd| {
        const shell = try std.fs.path.join(allocator, &.{ pwd, "index.html" });
        if (fileExists(io, shell)) return shell;
        allocator.free(shell);
    }

    const build_index = try std.fs.path.join(allocator, &.{ web_dir, "index.html" });
    if (fileExists(io, build_index)) return build_index;
    allocator.free(build_index);

    const game_html = try std.fs.path.join(allocator, &.{ web_dir, "game.html" });
    if (fileExists(io, game_html)) return game_html;
    allocator.free(game_html);

    return null;
}

// Interrupt the active read/write as well as the listener. Joining before
// closing the stream prevents a shutdown racing a reused socket handle.
fn cancelConnection(io: std.Io, stream: std.Io.net.Stream, cancel: *const std.atomic.Value(bool), stop: *const std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        if (cancel.load(.acquire)) {
            stream.shutdown(io, .both) catch {};
            return;
        }
        io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch return;
    }
}

/// Serve a single HTTP/1.1 request off `stream`, then close it.
/// Connection: close — no keep-alive; the dev loop reopens per asset.
fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    watch_state: ?*WatchState,
    cancel: ?*const std.atomic.Value(bool),
) !void {
    defer stream.close(io);
    var stop: std.atomic.Value(bool) = .init(false);
    const watcher = if (cancel) |flag| try std.Thread.spawn(.{}, cancelConnection, .{ io, stream, flag, &stop }) else null;
    defer if (watcher) |thread| {
        stop.store(true, .release);
        thread.join();
    };

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buf);
    var stream_writer = stream.writer(io, &send_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch |err| switch (err) {
        // Browser closed the socket before sending a full request line
        // (favicon probes, preconnect sockets) — nothing to answer.
        error.HttpConnectionClosing => return,
        else => return err,
    };

    if (request.head.method != .GET and request.head.method != .HEAD) {
        try request.respond("405 Method Not Allowed\n", .{ .status = .method_not_allowed });
        return;
    }

    // Strip URL query/fragment before decoding; an encoded '?' belongs to
    // the filename. Validate the decoded path so encoded traversal is refused.
    const path_end = std.mem.indexOfAny(u8, request.head.target, "?#") orelse request.head.target.len;
    const encoded = try allocator.dupe(u8, request.head.target[0..path_end]);
    defer allocator.free(encoded);
    const rel = resolvePath(std.Uri.percentDecodeInPlace(encoded));
    if (rel == null) {
        try request.respond("400 Bad Request\n", .{ .status = .bad_request });
        return;
    }

    // Live-reload version endpoint (cli#208). The injected client polls
    // this; the plain-text body is the current build version, bumped by
    // the watcher thread after a successful rebuild. A changed value tells
    // the page to reload. Answered before static routing so the reserved
    // path never hits the filesystem while watching. Without a watcher,
    // the route remains available to ordinary project assets.
    if (watch_state != null and watch_state.?.session != null and std.mem.eql(u8, rel.?, livereload_rel)) {
        const version = if (watch_state) |ws| ws.version.load(.acquire) else 0;
        var buf: [24]u8 = undefined;
        const vbody = std.fmt.bufPrint(&buf, "{d}", .{version}) catch "0";
        try request.respond(vbody, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
        return;
    }

    // A watch session serves the publication `output_dir` names right now,
    // resolved once for this request so its path checks and its read agree
    // on one generation. The previous publication is kept while a newer one
    // is switched in, so a request never sees a partial tree.
    // The generation this page is served from: read BEFORE resolving the
    // publication. The CLI switches `output_dir` first and advances the
    // generation after, so the embedded value is never newer than the files
    // served; at worst it is older, which costs one extra reload.
    const served_generation: u64 = if (watch_state) |ws| ws.version.load(.acquire) else 0;
    const published: ?[:0]u8 = if (watch_state) |ws| if (ws.session) |session| (watch.servedRoot(allocator, io, session) catch {
        try request.respond("503 Service Unavailable\n", .{ .status = .service_unavailable });
        return;
    }) else null else null;
    defer if (published) |dir| allocator.free(dir);
    const root_dir: []const u8 = published orelse web_dir;

    // The root request (`/` or a bare `/index.html`) is resolved
    // specially: prefer the project's clean shell, then a build-emitted
    // `index.html`, then emcc's `game.html`. Everything else is a plain
    // `root_dir`-relative asset. The root candidates are fixed filenames
    // — not user-controlled — so they don't need `resolveTarget`'s
    // traversal hardening.
    const file_path = if (isRootRequest(rel.?))
        (try resolveRoot(io, allocator, root_dir, project_web_dir)) orelse {
            try request.respond("404 Not Found\n", .{ .status = .not_found });
            return;
        }
    else
        try std.fs.path.join(allocator, &.{ root_dir, rel.? });
    defer allocator.free(file_path);

    // Recheck containment on every request: files may change after startup.
    // This also protects callers which use this server without provider preflight.
    const actual = std.Io.Dir.cwd().realPathFileAlloc(io, file_path, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            try request.respond("404 Not Found\n", .{ .status = .not_found });
            return;
        },
        else => return err,
    };
    defer allocator.free(actual);
    var contained = false;
    for ([_]?[]const u8{ root_dir, project_web_dir }) |candidate| {
        const source = candidate orelse continue;
        const root = std.Io.Dir.cwd().realPathFileAlloc(io, source, allocator) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(root);
        const parent = std.fs.path.dirname(actual) orelse "";
        const at_root = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(parent, root) else std.mem.eql(u8, parent, root);
        if (at_root and std.ascii.eqlIgnoreCase(std.fs.path.basename(actual), @import("assets.zig").state_file)) {
            try request.respond("403 Forbidden\n", .{ .status = .forbidden });
            return;
        }

        const prefix = if (builtin.os.tag == .windows) std.ascii.startsWithIgnoreCase(actual, root) else std.mem.startsWith(u8, actual, root);
        if (prefix and (actual.len == root.len or (actual.len > root.len and (std.fs.path.isSep(root[root.len - 1]) or std.fs.path.isSep(actual[root.len]))))) contained = true;
    }
    if (!contained) {
        try request.respond("403 Forbidden\n", .{ .status = .forbidden });
        return;
    }

    if ((try std.Io.Dir.cwd().statFile(io, actual, .{})).kind != .file) {
        try request.respond("404 Not Found\n", .{ .status = .not_found });
        return;
    }

    // For the root request the served file may be `game.html`; report
    // an HTML content-type regardless of the candidate that matched.
    const content_type = if (isRootRequest(rel.?)) "text/html; charset=utf-8" else mimeFor(rel.?);

    // Cap the read so a stray huge file in `root_dir` can't OOM the
    // server. 1 GiB is generous for a WASM bundle + assets.
    const max_file_bytes = 1024 * 1024 * 1024;
    const body = std.Io.Dir.cwd().readFileAlloc(io, actual, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            try request.respond("404 Not Found\n", .{ .status = .not_found });
            return;
        },
        // `readFileAlloc` reports a too-large file as a stream-limit
        // error; answer 413 instead of letting the connection die.
        error.StreamTooLong => {
            try request.respond("413 Payload Too Large\n", .{ .status = .payload_too_large });
            return;
        },
        else => return err,
    };
    defer allocator.free(body);

    // Served HTML gets the `labelle run` options first in <head> and, in a
    // watch session, the reload client seeded with its generation. Other
    // assets pass through untouched.
    const is_html = std.mem.startsWith(u8, content_type, "text/html");
    const env_script: ?[]const u8 = if (watch_state) |ws| ws.run_env_script else null;
    const with_env: []const u8 = if (is_html and env_script != null) try injectFirst(allocator, body, env_script.?) else body;
    defer if (with_env.ptr != body.ptr) allocator.free(with_env);
    const reload = is_html and watch_state != null and watch_state.?.session != null;
    const send_body: []const u8 = if (reload) try injectReloadScript(allocator, with_env, served_generation) else with_env;
    defer if (send_body.ptr != with_env.ptr) allocator.free(send_body);

    // `request.respond` omits the body for HEAD requests automatically
    // while still emitting a `content-length` reflecting the real file
    // size, so passing the full `body` is correct for GET and HEAD.
    try request.respond(send_body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            // WASM ships uncompressed and large; spare the browser a
            // re-fetch across reloads within a dev session.
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
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

fn resolvePath(raw_path: []const u8) ?[]const u8 {
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
        if (first_component and std.ascii.eqlIgnoreCase(seg, @import("assets.zig").state_file)) return null;
        first_component = false;
    }
    return path;
}

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

// ── Live reload / watch (cli#208) ────────────────────────────────────

/// Reserved request path the injected client polls for the build version.
const livereload_path = "/__labelle_livereload";
/// The `web_dir`-relative form `resolveTarget` yields for that path.
const livereload_rel = "__labelle_livereload";

/// The reload client spliced into served HTML in a watch session. It starts
/// from `generation`, the publication the page was served from, and polls
/// the version endpoint once a second; any other value reloads the page. A
/// generation published between serving the page and its first poll is
/// therefore a reload, not a new baseline. Plain ES5 + `fetch`.
fn reloadClient(allocator: std.mem.Allocator, generation: u64) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\<script>
        \\(function () {{
        \\  var current = "{d}";
        \\  function poll() {{
        \\    fetch("/__labelle_livereload", {{ cache: "no-store" }})
        \\      .then(function (r) {{ return r.text(); }})
        \\      .then(function (v) {{
        \\        if (v !== current) {{ location.reload(); return; }}
        \\        setTimeout(poll, 1000);
        \\      }})
        \\      .catch(function () {{ setTimeout(poll, 2000); }});
        \\  }}
        \\  poll();
        \\}})();
        \\</script>
        \\
    , .{generation});
}

/// The `labelle run` options (`run.env`: `LABELLE_SCENE`, `LABELLE_PROFILE`,
/// ...) for a page, as a script placed first in `<head>`: it publishes them
/// as `window.LABELLE_RUN_ENV` and adds a `Module.preRun` step copying them
/// into Emscripten's `ENV`, so the game's `getenv` (the engine's
/// `requestedScene()` reads `LABELLE_SCENE`) sees them as on desktop. The
/// Module object is created if absent and otherwise extended, which classic
/// glue (`var Module = typeof Module != "undefined" ? Module : {}`) and
/// `LabelleLoader.install(window.Module || {})` both keep. Null when there
/// are no options. Caller owns the result.
pub fn runEnvScript(allocator: std.mem.Allocator, env: []const RunEnv) !?[]u8 {
    if (env.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    try jws.beginObject();
    for (env) |pair| {
        try jws.objectField(pair.name);
        try jws.write(pair.value);
    }
    try jws.endObject();
    const json = out.written();
    // No `<` may reach the script element: `</script` (any case) would end
    // it and `<!--` changes how it is parsed. The JSON payload has `<` only
    // inside strings, where `\u003c` is the same character.
    const safe = try std.mem.replaceOwned(u8, allocator, json, "<", "\\u003c");
    defer allocator.free(safe);
    return try std.fmt.allocPrint(allocator,
        \\<script>
        \\window.LABELLE_RUN_ENV = {s};
        \\(function (m) {{
        \\  m.preRun = [].concat(m.preRun || []);
        \\  m.preRun.push(function () {{
        \\    var env = typeof ENV !== "undefined" ? ENV : m.ENV;
        \\    if (!env) return;
        \\    for (var k in window.LABELLE_RUN_ENV) env[k] = window.LABELLE_RUN_ENV[k];
        \\  }});
        \\}})(window.Module = window.Module || {{}});
        \\</script>
        \\
    , .{safe});
}

pub const RunEnv = struct { name: []const u8, value: []const u8 };

/// Shared between the generation poller and the serve loop (`watch.zig`).
const WatchState = watch.State;

/// Splice `script` into `html` just before `</body>` (or append it when
/// there's no body tag). Caller owns the returned buffer.
fn injectBeforeBodyEnd(allocator: std.mem.Allocator, html: []const u8, script: []const u8) ![]u8 {
    if (std.mem.lastIndexOf(u8, html, "</body>")) |idx| return std.mem.concat(allocator, u8, &.{ html[0..idx], script, html[idx..] });
    return std.mem.concat(allocator, u8, &.{ html, script });
}

/// Splice `script` ahead of every page script: right after the opening
/// `<head ...>` tag, the first page `<script>` or the opening `<body ...>`
/// tag, whichever comes first. So a page with no real `<head>` and a
/// synchronous script ahead of `<body>` still sees the options before it
/// runs. With none of them, it goes after the `<!doctype ...>` (never ahead
/// of it, which would put the page in quirks mode), else at the start. The
/// tags are found by `findTag`, a small tokenizer that skips comments,
/// raw-text element content and attribute values.
fn injectFirst(allocator: std.mem.Allocator, html: []const u8, script: []const u8) ![]u8 {
    var at: ?usize = null;
    if (findTag(html, "head")) |t| at = t.end;
    if (findTag(html, "script")) |t| at = @min(at orelse t.start, t.start);
    if (findTag(html, "body")) |t| at = @min(at orelse t.end, t.end);
    const pos = at orelse doctypeEnd(html);
    return std.mem.concat(allocator, u8, &.{ html[0..pos], script, html[pos..] });
}

/// The index just past a leading `<!doctype ...>` (after optional
/// whitespace), else 0.
fn doctypeEnd(html: []const u8) usize {
    const lead = html.len - std.mem.trimStart(u8, html, " \t\r\n").len;
    const rest = html[lead..];
    if (rest.len < "<!doctype".len or !std.ascii.eqlIgnoreCase(rest[0.."<!doctype".len], "<!doctype")) return 0;
    const gt = std.mem.indexOfScalarPos(u8, html, lead, '>') orelse return 0;
    return gt + 1;
}

/// The index just past the `>` of the first real `<name ...>` start tag.
fn tagEnd(html: []const u8, name: []const u8) ?usize {
    return if (findTag(html, name)) |t| t.end else null;
}

const Tag = struct { start: usize, end: usize };

/// The first real `<name ...>` start tag: `start` at its `<`, `end` just
/// past its `>`. Found by `StartTags`, so text inside comments, raw-text
/// elements and attribute values never matches, and the name matches
/// case-insensitively and whole (`<header>` is not `<head>`).
fn findTag(html: []const u8, name: []const u8) ?Tag {
    var tags: StartTags = .{ .html = html };
    while (tags.next()) |t| if (std.ascii.eqlIgnoreCase(t.name, name)) return .{ .start = t.start, .end = t.end };
    return null;
}

/// A small HTML tokenizer that yields start tags in document order. It
/// skips `<!-- ... -->` comments, `<!doctype>`-like and `<?...>`
/// declarations, end tags, the content of raw-text elements (`<script>`,
/// `<style>`, `<textarea>`, `<title>`, ...) up to their closing tag, and
/// quoted attribute values (which may contain `<` and `>`), and never
/// yields a tag inside `<template>` content, nested or not. Anything
/// unterminated (a comment, a tag, a raw-text element, a template) hides
/// the rest of the page.
const StartTags = struct {
    html: []const u8,
    i: usize = 0,
    /// Open `<template>` levels: nothing inside one is yielded.
    template_depth: usize = 0,

    const raw_text = [_][]const u8{ "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes" };

    const Found = struct { name: []const u8, start: usize, end: usize };

    fn next(self: *StartTags) ?Found {
        const html = self.html;
        while (std.mem.indexOfScalarPos(u8, html, self.i, '<')) |lt| {
            const rest = html[lt..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const close = std.mem.indexOfPos(u8, html, lt + 4, "-->") orelse return self.stop();
                self.i = close + 3;
                continue;
            }
            if (rest.len > 1 and (rest[1] == '!' or rest[1] == '?' or rest[1] == '/')) {
                // Declarations and end tags: skip to their `>`. A
                // `</template>` closes one level of template content.
                const gt = std.mem.indexOfScalarPos(u8, html, lt + 1, '>') orelse return self.stop();
                if (rest[1] == '/' and self.template_depth > 0 and std.ascii.eqlIgnoreCase(tagName(html, lt + 2), "template"))
                    self.template_depth -= 1;
                self.i = gt + 1;
                continue;
            }
            if (rest.len < 2 or !std.ascii.isAlphabetic(rest[1])) {
                self.i = lt + 1; // a bare `<` in text
                continue;
            }
            const name = tagName(html, lt + 1);
            const end = attributesEnd(html, lt + 1 + name.len) orelse return self.stop();
            self.i = end;
            for (raw_text) |raw| if (std.ascii.eqlIgnoreCase(name, raw)) {
                self.i = closingTag(html, end, raw) orelse html.len;
                break;
            };
            // Template content is inert, however deeply nested: count the
            // levels and yield nothing inside them.
            if (std.ascii.eqlIgnoreCase(name, "template")) {
                self.template_depth += 1;
                continue;
            }
            if (self.template_depth > 0) continue;
            return .{ .name = name, .start = lt, .end = end };
        }
        return self.stop();
    }

    /// The tag name starting at `from`: up to whitespace, `/` or `>`.
    fn tagName(html: []const u8, from: usize) []const u8 {
        var j = from;
        while (j < html.len and !std.ascii.isWhitespace(html[j]) and html[j] != '/' and html[j] != '>') j += 1;
        return html[from..j];
    }

    fn stop(self: *StartTags) ?Found {
        self.i = self.html.len;
        return null;
    }

    /// Past the `>` closing a start tag whose name ends at `from`: quoted
    /// values (after `=`) are skipped whole.
    fn attributesEnd(html: []const u8, from: usize) ?usize {
        var j = from;
        while (j < html.len) : (j += 1) switch (html[j]) {
            '>' => return j + 1,
            '=' => {
                j += 1;
                while (j < html.len and std.ascii.isWhitespace(html[j])) j += 1;
                if (j < html.len and (html[j] == '"' or html[j] == '\'')) {
                    j = std.mem.indexOfScalarPos(u8, html, j + 1, html[j]) orelse return null;
                } else j -= 1;
            },
            else => {},
        };
        return null;
    }

    /// The index of `</name` (any case, then whitespace, `/` or `>`) at or
    /// after `from`: where a raw-text element's content ends.
    fn closingTag(html: []const u8, from: usize, name: []const u8) ?usize {
        var k = from;
        while (std.mem.indexOfPos(u8, html, k, "</")) |at| {
            const e = at + 2 + name.len;
            if (e <= html.len and std.ascii.eqlIgnoreCase(html[at + 2 .. e], name) and
                (e == html.len or html[e] == '>' or html[e] == '/' or std.ascii.isWhitespace(html[e]))) return at;
            k = at + 2;
        }
        return null;
    }
};

/// The reload client for `generation`, before `</body>`.
fn injectReloadScript(allocator: std.mem.Allocator, html: []const u8, generation: u64) ![]u8 {
    const client = try reloadClient(allocator, generation);
    defer allocator.free(client);
    return injectBeforeBodyEnd(allocator, html, client);
}

// ── Tests ───────────────────────────────────────────────────────────
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

/// Accept `n` connections then return — the test side of the loop in
/// `serveAndOpen`. Lives in a thread so the test's request side can
/// drive the real `std.Io.net` round-trip in-process.
fn testServeN(
    io: std.Io,
    alloc: std.mem.Allocator,
    server: *std.Io.net.Server,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    n: usize,
) void {
    testServeNWatch(io, alloc, server, web_dir, project_web_dir, n, null);
}

/// Like `testServeN` but with an explicit watch state, so tests can drive
/// the `--watch` request paths (version endpoint + HTML injection).
fn testServeNWatch(
    io: std.Io,
    alloc: std.mem.Allocator,
    server: *std.Io.net.Server,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    n: usize,
    watch_state: ?*WatchState,
) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const stream = server.accept(io) catch return;
        handleConnection(io, alloc, stream, web_dir, project_web_dir, watch_state, null) catch {};
    }
}

/// Bind 127.0.0.1 on the first free port in a fixed candidate range.
/// Avoids needing `getsockname` to discover a port-0 assignment —
/// that symbol isn't linked in Zig's Windows std, so the port-0 +
/// getsockname trick fails to compile on Windows.
fn testBindFreePort(io: std.Io) ?struct { server: std.Io.net.Server, port: u16 } {
    var port: u16 = 49500;
    while (port < 49600) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const server = addr.listen(io, .{ .reuse_address = true }) catch continue;
        return .{ .server = server, .port = port };
    }
    return null;
}

test "handleConnection: serves a file, 404s a miss, 400s traversal" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Portable, auto-cleaned temp dir under .zig-cache/tmp/<sub_path>.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(web_dir);

    try tmp.dir.writeFile(io, .{
        .sub_path = "labelle_serve_test.html",
        .data = "<h1>hi</h1>",
    });

    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    const port = bound.port;
    defer server.deinit(io);

    const t = try std.Thread.spawn(.{}, testServeN, .{ io, alloc, &server, web_dir, @as(?[]const u8, null), @as(usize, 3) });
    defer t.join();

    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const Case = struct { target: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .target = "/labelle_serve_test.html", .want = "<h1>hi</h1>" },
        .{ .target = "/no_such_file.wasm", .want = "404" },
        .{ .target = "/../../etc/passwd", .want = "400" },
    }) |case| {
        const s = try peer.connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [512]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.print(
            "GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
            .{case.target},
        );
        try w.interface.flush();

        var rbuf: [8192]u8 = undefined;
        var r = s.reader(io, &rbuf);
        const resp = try r.interface.allocRemaining(alloc, .unlimited);
        defer alloc.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, case.want) != null);
    }
}

/// Issue a single `GET /` over loopback and return the full response.
/// Caller frees the result.
fn testRootRequest(
    io: std.Io,
    alloc: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
) ![]u8 {
    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    const port = bound.port;
    defer server.deinit(io);

    const t = try std.Thread.spawn(.{}, testServeN, .{ io, alloc, &server, web_dir, project_web_dir, @as(usize, 1) });
    defer t.join();

    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const s = try peer.connect(io, .{ .mode = .stream });
    defer s.close(io);
    var wbuf: [512]u8 = undefined;
    var w = s.writer(io, &wbuf);
    try w.interface.print("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{});
    try w.interface.flush();

    var rbuf: [8192]u8 = undefined;
    var r = s.reader(io, &rbuf);
    return r.interface.allocRemaining(alloc, .unlimited);
}

test "handleConnection: root prefers the project web/index.html shell" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Build output dir: holds emcc's game.html only.
    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{ .sub_path = "game.html", .data = "<!-- emcc shell -->" });

    // Project web dir: holds the clean shell.
    var proj_tmp = std.testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    const project_web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &proj_tmp.sub_path });
    defer alloc.free(project_web_dir);
    try proj_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<!-- clean shell -->" });

    const resp = try testRootRequest(io, alloc, web_dir, project_web_dir);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "clean shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "emcc shell") == null);
}

test "handleConnection: root falls back to game.html when no project shell" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{ .sub_path = "game.html", .data = "<!-- emcc shell -->" });

    // Project web dir exists but has no index.html.
    var proj_tmp = std.testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    const project_web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &proj_tmp.sub_path });
    defer alloc.free(project_web_dir);

    const resp = try testRootRequest(io, alloc, web_dir, project_web_dir);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "emcc shell") != null);
}

test "handleConnection: root prefers a build-emitted index.html over game.html" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{ .sub_path = "game.html", .data = "<!-- emcc shell -->" });
    try build_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<!-- build index -->" });

    const resp = try testRootRequest(io, alloc, web_dir, null);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "build index") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "emcc shell") == null);
}

test "handleConnection: root 404s when neither a shell nor game.html exists" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);

    const resp = try testRootRequest(io, alloc, web_dir, null);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "404") != null);
}

test "injectReloadScript: splices before </body>" {
    const alloc = std.testing.allocator;
    const html = "<html><body><canvas></canvas></body></html>";
    const out = try injectReloadScript(alloc, html, 0);
    defer alloc.free(out);
    // The client script is present...
    try std.testing.expect(std.mem.indexOf(u8, out, "__labelle_livereload") != null);
    // ...and it lands before the closing body tag, not after it.
    const script_at = std.mem.indexOf(u8, out, "location.reload").?;
    const body_at = std.mem.indexOf(u8, out, "</body>").?;
    try std.testing.expect(script_at < body_at);
    // Original content is preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, "<canvas>") != null);
}

test "injectReloadScript: appends when there is no </body>" {
    const alloc = std.testing.allocator;
    const html = "<h1>bare fragment</h1>";
    const out = try injectReloadScript(alloc, html, 0);
    defer alloc.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "<h1>bare fragment</h1>"));
    try std.testing.expect(std.mem.indexOf(u8, out, "__labelle_livereload") != null);
}
/// One GET through `handleConnection` on its own thread; returns the response.
fn testGet(io: std.Io, alloc: std.mem.Allocator, server: *std.Io.net.Server, port: u16, web_dir: []const u8, state: ?*WatchState, target: []const u8) ![]u8 {
    const t = try std.Thread.spawn(.{}, testServeNWatch, .{ io, alloc, server, web_dir, @as(?[]const u8, null), @as(usize, 1), state });
    defer t.join();
    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const s = try peer.connect(io, .{ .mode = .stream });
    defer s.close(io);
    var wbuf: [512]u8 = undefined;
    var w = s.writer(io, &wbuf);
    try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{target});
    try w.interface.flush();
    var rbuf: [8192]u8 = undefined;
    var r = s.reader(io, &rbuf);
    return r.interface.allocRemaining(alloc, .unlimited);
}

fn testBody(resp: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return resp;
    return resp[at + 4 ..];
}

test "handleConnection: a watch session seeds the reload client with the served generation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "out/web");
    try tmp.dir.writeFile(io, .{ .sub_path = "out/web/index.html", .data = "<html><body><canvas id=game></canvas></body></html>" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const out = try std.fs.path.join(alloc, &.{ root, "out" });
    defer alloc.free(out);
    const gen = try std.fs.path.join(alloc, &.{ root, "generation" });
    defer alloc.free(gen);
    var wstate = WatchState{ .session = .{ .generation_file = gen, .output_dir = out } };
    wstate.version.store(1, .release);

    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    defer server.deinit(io);

    // The page is served at generation 1 and says so.
    const page = try testGet(io, alloc, &server, bound.port, root, &wstate, "/");
    defer alloc.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "var current = \"1\";") != null);
    // The race: generation 2 is published before the page's first poll.
    wstate.version.store(2, .release);
    const polled = try testGet(io, alloc, &server, bound.port, root, &wstate, "/__labelle_livereload");
    defer alloc.free(polled);
    try std.testing.expectEqualStrings("2", testBody(polled));
    // The client compares with its seed, never adopts the first answer as
    // its baseline: "2" !== "1" reloads the page.
    try std.testing.expect(std.mem.indexOf(u8, page, "current === null") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "if (v !== current) { location.reload(); return; }") != null);
}

test "handleConnection: run options reach the page first in <head>; the endpoint stays a file outside watch" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<!doctype html><html><HEAD lang=en><script>var Module={};</script></head><body></body></html>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "__labelle_livereload", .data = "asset" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const script = (try runEnvScript(alloc, &.{ .{ .name = "LABELLE_SCENE", .value = "intro</script>" }, .{ .name = "LABELLE_PROFILE", .value = "1" } })).?;
    defer alloc.free(script);
    var wstate = WatchState{ .run_env_script = script };
    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    defer server.deinit(io);

    const page = try testGet(io, alloc, &server, bound.port, root, &wstate, "/");
    defer alloc.free(page);
    const env_at = std.mem.indexOf(u8, page, "window.LABELLE_RUN_ENV = {\"LABELLE_SCENE\":\"intro\\u003c/script>\",\"LABELLE_PROFILE\":\"1\"};").?;
    try std.testing.expect(env_at > std.mem.indexOf(u8, page, "<HEAD lang=en>").?);
    try std.testing.expect(env_at < std.mem.indexOf(u8, page, "var Module={}").?);
    try std.testing.expect(std.mem.indexOf(u8, page, "location.reload") == null);
    const asset = try testGet(io, alloc, &server, bound.port, root, &wstate, "/__labelle_livereload");
    defer alloc.free(asset);
    try std.testing.expectEqualStrings("asset", testBody(asset));
}

test "runEnvScript: no `<` reaches the script element, whatever its case" {
    const alloc = std.testing.allocator;
    const script = (try runEnvScript(alloc, &.{.{ .name = "LABELLE_SCENE", .value = "a</ScRiPt><!--b" }})).?;
    defer alloc.free(script);
    const body = script["<script>".len..std.mem.lastIndexOf(u8, script, "</script>").?];
    try std.testing.expect(std.mem.indexOfScalar(u8, body, '<') == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"a\\u003c/ScRiPt>\\u003c!--b\"") != null);
    // And it is still the same string once parsed as JSON.
    const start = std.mem.indexOf(u8, body, "{").?;
    const json = body[start .. std.mem.indexOf(u8, body, "};").? + 1];
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a</ScRiPt><!--b", parsed.value.object.get("LABELLE_SCENE").?.string);
}

test "tagEnd skips comments, matches whole names in any case, allows attributes" {
    const html = "<!doctype html><!-- <head> old --><HTML><header x=1></header><Head data-x=\"a>b\">T</head>";
    const at = tagEnd(html, "head").?;
    try std.testing.expectEqualStrings("T</head>", html[at..]);
    try std.testing.expectEqual(@as(?usize, null), tagEnd("<!-- <head> -->", "head"));
    try std.testing.expectEqual(@as(?usize, null), tagEnd("<p><!-- unterminated <head>", "head"));
    const alloc = std.testing.allocator;
    const got = try injectFirst(alloc, "<!-- <head> --><html><head><title>t</title></head></html>", "S");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("<!-- <head> --><html><head>S<title>t</title></head></html>", got);
    const bare = try injectFirst(alloc, "<!-- <head> --><p>x</p>", "S");
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("S<!-- <head> --><p>x</p>", bare);
}

test "injectFirst: after <head>, else <body>, else at the start; never inside <header>" {
    const alloc = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "<html><head><title>t</title></head></html>", "<html><head>S<title>t</title></head></html>" },
        .{ "<html><body class=x><header>h</header></body></html>", "<html><body class=x>S<header>h</header></body></html>" },
        .{ "<p>fragment</p>", "S<p>fragment</p>" },
        // No <head>: before the first script, even one ahead of <body>.
        .{ "<!DOCTYPE html><html><script>var Module={};</script><body><canvas></canvas></body></html>", "<!DOCTYPE html><html>S<script>var Module={};</script><body><canvas></canvas></body></html>" },
        .{ "<!doctype html><SCRIPT src=early.js></SCRIPT><body></body>", "<!doctype html>S<SCRIPT src=early.js></SCRIPT><body></body>" },
        .{ "<!-- <script> --><html><body><script>x</script></body></html>", "<!-- <script> --><html><body>S<script>x</script></body></html>" },
        .{ "<html><scripts></scripts><body>b</body></html>", "<html><scripts></scripts><body>Sb</body></html>" },
        // Neither head, script nor body: after the doctype, never ahead of it.
        .{ "<!DOCTYPE html>\n<p>x</p>", "<!DOCTYPE html>S\n<p>x</p>" },
        .{ "  <!doctype html><p>x</p>", "  <!doctype html>S<p>x</p>" },
        // Tag-like text in raw-text content or attribute values is not a tag.
        .{ "<html><style>x::after{content:\"<script>\"}</style><body><p>x</p></body></html>", "<html><style>x::after{content:\"<script>\"}</style><body>S<p>x</p></body></html>" },
        .{ "<html><head data-x=\"<script>\"><script>a</script></head></html>", "<html><head data-x=\"<script>\">S<script>a</script></head></html>" },
        .{ "<html><p title='<body>'>x</p><title><script></title><script>a</script>", "<html><p title='<body>'>x</p><title><script></title>S<script>a</script>" },
        .{ "<html><textarea><body></TEXTAREA ><body>b", "<html><textarea><body></TEXTAREA ><body>Sb" },
        .{ "<!doctype html><script>var s=\"<body>\";</script>", "<!doctype html>S<script>var s=\"<body>\";</script>" },
        .{ "<!doctype html><style><body>", "<!doctype html>S<style><body>" },
        // Template content is inert, however nested; unterminated, it hides the rest.
        .{ "<!doctype html><html><template><script>t</script></template><body><script>b</script></body>", "<!doctype html><html><template><script>t</script></template><body>S<script>b</script></body>" },
        .{ "<html><template><template><p/></template><script>t</script><body></template><script>a</script>", "<html><template><template><p/></template><script>t</script><body></template>S<script>a</script>" },
        .{ "<html><TEMPLATE x=\"</template>\"><style></template></style><script>t</script></Template ><script>a</script>", "<html><TEMPLATE x=\"</template>\"><style></template></style><script>t</script></Template >S<script>a</script>" },
        .{ "<!DOCTYPE html><template><template></template><script>t</script><body>b", "<!DOCTYPE html>S<template><template></template><script>t</script><body>b" },
        // A script ahead of a late <head> runs before it: go first.
        .{ "<script>a</script><head><title>t</title></head>", "S<script>a</script><head><title>t</title></head>" },
        .{ "<html><head><script>a</script></head><script>b</script>", "<html><head>S<script>a</script></head><script>b</script>" },
    }) |case| {
        const got = try injectFirst(alloc, case[0], "S");
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
    try std.testing.expectEqual(@as(?[]u8, null), try runEnvScript(alloc, &.{}));
}

test "handleConnection: a watch session serves the publication output_dir names, never web_dir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // symlinks need a privilege; the e2e covers junctions
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "published-0/web");
    try tmp.dir.createDirPath(io, "published-1/web");
    try tmp.dir.createDirPath(io, "staging/web");
    try tmp.dir.writeFile(io, .{ .sub_path = "published-0/web/data.txt", .data = "gen-zero" });
    try tmp.dir.writeFile(io, .{ .sub_path = "published-1/web/data.txt", .data = "gen-one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "staging/web/data.txt", .data = "half-built" });
    try tmp.dir.symLink(io, "published-0", "current", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const current = try std.fs.path.join(alloc, &.{ root, "current" });
    defer alloc.free(current);
    const staging = try std.fs.path.join(alloc, &.{ root, "staging", "web" });
    defer alloc.free(staging);
    var wstate = WatchState{ .session = .{ .generation_file = current, .output_dir = current } };

    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    defer server.deinit(io);
    const peer = std.Io.net.IpAddress.parse("127.0.0.1", bound.port) catch unreachable;
    for ([_][]const u8{ "gen-zero", "gen-one" }, 0..) |want, n| {
        if (n == 1) {
            // The CLI publishes by renaming a new link over `current`.
            try tmp.dir.symLink(io, "published-1", "next", .{ .is_directory = true });
            try tmp.dir.rename("next", tmp.dir, "current", io);
        }
        const t = try std.Thread.spawn(.{}, testServeNWatch, .{ io, alloc, &server, staging, @as(?[]const u8, null), @as(usize, 1), &wstate });
        defer t.join();
        const s = try peer.connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [256]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.print("GET /data.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{});
        try w.interface.flush();
        var rbuf: [4096]u8 = undefined;
        var r = s.reader(io, &rbuf);
        const resp = try r.interface.allocRemaining(alloc, .unlimited);
        defer alloc.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, want) != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "half-built") == null);
    }
}

test "handleConnection: without --watch, HTML is served untouched and the endpoint is inert" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{
        .sub_path = "index.html",
        .data = "<html><body>plain</body></html>",
    });

    const resp = try testRootRequest(io, alloc, web_dir, null);
    defer alloc.free(resp);
    // No watcher → no injected client script.
    try std.testing.expect(std.mem.indexOf(u8, resp, "__labelle_livereload") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "plain") != null);
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
    // Returns (no error) only because the deadline asked for the stop.
    try serveAndOpen(std.testing.allocator, root, null, bound.port, false, null, &.{}, 300);
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
    try std.testing.expect(cancel_requested.load(.acquire));
    try std.testing.expect(elapsed >= 300);
    try std.testing.expect(elapsed < 10_000);
}

test "deadlineLoop: sets the stop flag after the deadline, not when stopped first" {
    const io = std.testing.io;
    var cancel: std.atomic.Value(bool) = .init(false);
    var stop: std.atomic.Value(bool) = .init(true);
    deadlineLoop(io, 10_000, &cancel, &stop);
    try std.testing.expect(!cancel.load(.acquire));
    stop.store(false, .release);
    deadlineLoop(io, 30, &cancel, &stop);
    try std.testing.expect(cancel.load(.acquire));
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
