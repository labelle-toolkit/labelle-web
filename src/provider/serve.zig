/// Static file server extracted from labelle-cli at 5eccdbc.
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
            std.debug.print("labelle: accept failed ({s}), continuing\n", .{@errorName(err)});
            continue;
        };
        if (cancel.load(.acquire)) {
            stream.close(io);
            return;
        }
        handleConnection(io, allocator, stream, web_dir, project_web_dir, watch_state) catch |err| {
            std.debug.print("labelle: connection error ({s})\n", .{@errorName(err)});
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
/// `watch` (cli#208) enables the rebuild-on-change live-reload loop: a
/// background thread polls `watch.watch_dir`, runs `watch.rebuild_fn` on
/// change, and bumps a shared build version that connected browsers poll
/// via an injected client snippet (`/__labelle_livereload`). Pass `null`
/// for a plain static serve.
pub fn serveAndOpen(
    allocator: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    port: u16,
    open_browser_tab: bool,
    watch: ?WatchConfig,
) !void {
    const io = config.globalIo();

    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print(
            "labelle: could not bind 127.0.0.1:{d} ({s}).\n" ++
                "  Another server may already be on that port — try a different --port.\n",
            .{ port, @errorName(err) },
        );
        return err;
    };
    defer server.deinit(io);

    // The stop handler and its waker come first, so a Ctrl+C at any point
    // after the bind ends the loop instead of the process. `wstate.stop`
    // also ends the waker if the loop is left some other way.
    installCancelHandler();
    var wstate = WatchState{};
    const waker: ?std.Thread = std.Thread.spawn(.{}, wakeLoop, .{ io, port, &cancel_requested, &wstate.stop }) catch |err| blk: {
        std.debug.print("labelle: could not start the stop watcher ({s}); Ctrl+C ends the process without after-run hooks\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (waker) |t| {
        wstate.stop.store(true, .release);
        t.join();
    };

    // Start the file watcher before printing the banner so its status is
    // reflected. `wstate` lives on this frame — `serveAndOpen` blocks until
    // the stop is asked for, so it outlives the watcher thread and every
    // connection.
    var watch_thread: ?std.Thread = null;
    if (watch) |cfg| {
        watch_thread = std.Thread.spawn(.{}, watchLoop, .{ io, cfg, &wstate }) catch |err| blk: {
            std.debug.print(
                "labelle: could not start file watcher ({s}); serving without --watch\n",
                .{@errorName(err)},
            );
            break :blk null;
        };
    }
    defer if (watch_thread) |t| {
        wstate.stop.store(true, .release);
        t.join();
    };
    // Only inject the reload client + answer the version endpoint when a
    // watcher is actually running.
    const watch_state: ?*WatchState = if (watch_thread != null) &wstate else null;

    std.debug.print(
        "labelle: serving {s}\n" ++
            "  Local:   http://127.0.0.1:{d}\n" ++
            "{s}" ++
            "  Press Ctrl+C to stop\n",
        .{
            web_dir,
            port,
            if (watch_state != null) "  Watching for changes — edits rebuild + live-reload\n" else "",
        },
    );

    if (open_browser_tab) openBrowser(allocator, port);

    serveLoop(io, allocator, &server, web_dir, project_web_dir, watch_state, &cancel_requested);
    std.debug.print("\nlabelle: stopping server\n", .{});
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

/// Serve a single HTTP/1.1 request off `stream`, then close it.
/// Connection: close — no keep-alive; the dev loop reopens per asset.
fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    watch_state: ?*WatchState,
) !void {
    defer stream.close(io);

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

    const rel = resolveTarget(request.head.target);
    if (rel == null) {
        try request.respond("400 Bad Request\n", .{ .status = .bad_request });
        return;
    }

    // Live-reload version endpoint (cli#208). The injected client polls
    // this; the plain-text body is the current build version, bumped by
    // the watcher thread after a successful rebuild. A changed value tells
    // the page to reload. Answered before static routing so the reserved
    // path never hits the filesystem. Returns `0` when no watcher is
    // running (a stray poll from a cached page won't ever reload).
    if (std.mem.eql(u8, rel.?, livereload_rel)) {
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

    // The root request (`/` or a bare `/index.html`) is resolved
    // specially: prefer the project's clean shell, then a build-emitted
    // `index.html`, then emcc's `game.html`. Everything else is a plain
    // `web_dir`-relative asset. The root candidates are fixed filenames
    // — not user-controlled — so they don't need `resolveTarget`'s
    // traversal hardening.
    const file_path = if (isRootRequest(rel.?))
        (try resolveRoot(io, allocator, web_dir, project_web_dir)) orelse {
            try request.respond("404 Not Found\n", .{ .status = .not_found });
            return;
        }
    else
        try std.fs.path.join(allocator, &.{ web_dir, rel.? });
    defer allocator.free(file_path);

    // For the root request the served file may be `game.html`; report
    // an HTML content-type regardless of the candidate that matched.
    const content_type = if (isRootRequest(rel.?)) "text/html; charset=utf-8" else mimeFor(rel.?);

    // Cap the read so a stray huge file in `web_dir` can't OOM the
    // server. 1 GiB is generous for a WASM bundle + assets.
    const max_file_bytes = 1024 * 1024 * 1024;
    const body = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
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

    // Under `--watch`, splice the live-reload client into served HTML so
    // the open tab starts polling the version endpoint. Non-HTML assets
    // (wasm/js/png/…) and non-watch serves pass through untouched.
    const is_html = std.mem.startsWith(u8, content_type, "text/html");
    const send_body: []const u8 = if (watch_state != null and is_html)
        try injectReloadScript(allocator, body)
    else
        body;
    defer if (send_body.ptr != body.ptr) allocator.free(send_body);

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

    if (path.len == 0 or path[0] != '/') return null;

    // Reject any backslash outright. A legit web asset path never has
    // one, and on Windows '\' is a path separator — so a target like
    // "/..\..\windows\win.ini" would otherwise be a single segment
    // that dodges the '..' check below and escapes `web_dir`.
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;

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
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return null;
        // Match path components, including /./ aliases and case-insensitive
        // host filesystems, so build-only page provenance never gets served.
        if (std.ascii.eqlIgnoreCase(seg, @import("assets.zig").state_file)) return null;
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

/// Client snippet spliced into served HTML under `--watch`. Polls the
/// version endpoint once a second; when the value changes (the watcher
/// bumped it after a rebuild) it reloads the page. Plain ES5 + `fetch`,
/// no dependencies — works in every browser that can run a WASM game.
const reload_client_js =
    \\<script>
    \\(function () {
    \\  var current = null;
    \\  function poll() {
    \\    fetch("/__labelle_livereload", { cache: "no-store" })
    \\      .then(function (r) { return r.text(); })
    \\      .then(function (v) {
    \\        if (current === null) { current = v; }
    \\        else if (v !== current) { location.reload(); return; }
    \\        setTimeout(poll, 1000);
    \\      })
    \\      .catch(function () { setTimeout(poll, 2000); });
    \\  }
    \\  poll();
    \\})();
    \\</script>
    \\
;

/// The rebuild callback signature. Returns true on a clean rebuild, false
/// on any failure (the server stays up; the browser is NOT reloaded onto a
/// broken build).
pub const RebuildFn = *const fn (ctx: *anyopaque) bool;

/// Watch configuration passed to `serveAndOpen`.
pub const WatchConfig = struct {
    /// Project source tree to poll for changes. Build-output and VCS dirs
    /// (`.labelle`, `.git`, `zig-out`, …) are skipped so a rebuild — which
    /// writes into `.labelle/` — can't trigger itself.
    watch_dir: []const u8,
    /// Invoked (on the watcher thread) after a debounced change.
    rebuild_fn: RebuildFn,
    /// Opaque payload handed back to `rebuild_fn`.
    rebuild_ctx: *anyopaque,
    /// Poll cadence.
    poll_interval_ms: u32 = 400,
    /// Consecutive stable polls required before firing a rebuild — debounces
    /// a burst of saves into a single build. Minimum 1.
    quiet_polls: u32 = 2,
    /// Files the rebuild itself WRITES into the watched tree: the declared
    /// `.outputs` of the project's `.prebuild` steps (cli#355), as paths
    /// rooted the same way the walk builds them — see `watchIgnorePath`.
    ///
    /// They are excluded from the signature entirely, the same way
    /// `.labelle/` already is. Folding them in made a hook's own
    /// regeneration look like a fresh edit: `applied` is the signature
    /// captured BEFORE the rebuild callback, so the next poll saw the
    /// hook's write as a new change and ran a SECOND full
    /// generate/compile/browser-reload for it.
    ///
    /// Excluding rather than re-snapshotting after every callback is
    /// deliberate: a re-snapshot would also swallow a source file the
    /// user saved DURING the rebuild, which is a silently dropped edit —
    /// strictly worse than a redundant one. A declared output is a
    /// generated target, not a source; the input that produces it is
    /// still watched, so a real change still fires exactly one rebuild.
    ///
    /// Writers with no such declaration — provider lifecycle hooks, a
    /// prebuild step without `.outputs` — are bounded by `WatchBaseline`
    /// instead: their write costs a bounded number of follow-up rebuilds
    /// (one when it rewrites the same paths), never a loop.
    ignore_files: []const []const u8 = &.{},
};

/// Shared state between the watcher thread and the serve loop. `version`
/// is what the browser polls; `stop` lets `serveAndOpen`'s defer join the
/// thread cleanly (only exercised if the accept loop ever returns).
const WatchState = struct {
    version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Directory names skipped while walking the watch tree. `.labelle` is the
/// load-bearing one — the rebuild writes there, so watching it would loop.
const watch_skip_dirs = [_][]const u8{ "zig-out", "zig-cache", "zig-pkg" };

/// A cheap fingerprint of a source tree: a file count plus a `digest`
/// that folds in every file's `(path, size, mtime)`. Folding per file
/// (rather than only summing sizes + tracking the single newest mtime)
/// makes the signature sensitive to *any* single-file change — including a
/// same-size edit to a non-newest file, or swapping content between two
/// files — so any add / edit / remove / mtime-change flips it.
const TreeSignature = struct {
    file_count: u64 = 0,
    /// Order-independent digest: each file contributes an independent
    /// 64-bit hash of its path+size+mtime, XOR-folded in. XOR is
    /// commutative, so directory iteration order doesn't matter, and a
    /// change to any single file toggles the bits its hash owns.
    digest: u64 = 0,

    /// Fold one file's identity into the signature.
    fn mix(self: *TreeSignature, path: []const u8, size: u64, mtime_ns: i128) void {
        var h = std.hash.Wyhash.init(0);
        h.update(path);
        h.update(std.mem.asBytes(&size));
        const m: i128 = mtime_ns;
        h.update(std.mem.asBytes(&m));
        self.file_count += 1;
        self.digest ^= h.final();
    }

    fn eql(a: TreeSignature, b: TreeSignature) bool {
        return a.file_count == b.file_count and a.digest == b.digest;
    }
};

/// One file's entry in a `TreeSnapshot`: a hash of its path (`key`) and of
/// its `(size, mtime)` (`state`).
const PathState = struct {
    key: u64,
    state: u64,

    fn lessThan(_: void, a: PathState, b: PathState) bool {
        return a.key < b.key;
    }
};

/// The key a path gets in a `TreeSnapshot`.
fn pathKey(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0, path);
}

/// The watched tree at one instant: its `TreeSignature` plus every file's
/// `PathState`, sorted by key, so two snapshots can be diffed per path
/// (`changedPaths`). Taken only around a rebuild — the cheap signature
/// alone still drives the polls.
const TreeSnapshot = struct {
    sig: TreeSignature = .{},
    paths: std.ArrayList(PathState) = .empty,
    /// False when recording a path failed (out of memory): the per-path
    /// view is partial, so no delta can be drawn from it.
    complete: bool = true,

    fn record(self: *TreeSnapshot, a: std.mem.Allocator, path: []const u8, size: u64, mtime_ns: i128) void {
        self.sig.mix(path, size, mtime_ns);
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&size));
        const m: i128 = mtime_ns;
        h.update(std.mem.asBytes(&m));
        self.paths.append(a, .{ .key = pathKey(path), .state = h.final() }) catch {
            self.complete = false;
        };
    }

    fn sort(self: *TreeSnapshot) void {
        std.mem.sort(PathState, self.paths.items, {}, PathState.lessThan);
    }
};

/// The keys of the paths added, removed or changed between two sorted
/// snapshots, ascending. Caller owns the result.
fn changedPaths(a: std.mem.Allocator, before: []const PathState, after: []const PathState) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var j: usize = 0;
    while (i < before.len or j < after.len) {
        if (j == after.len or (i < before.len and before[i].key < after[j].key)) {
            try out.append(a, before[i].key);
            i += 1;
        } else if (i == before.len or after[j].key < before[i].key) {
            try out.append(a, after[j].key);
            j += 1;
        } else {
            if (before[i].state != after[j].state) try out.append(a, before[i].key);
            i += 1;
            j += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// How many keys of sorted `keys` are not in sorted `seen`.
fn countNovel(keys: []const u64, seen: []const u64) usize {
    var n: usize = 0;
    var j: usize = 0;
    for (keys) |key| {
        while (j < seen.len and seen[j] < key) j += 1;
        if (j == seen.len or seen[j] != key) n += 1;
    }
    return n;
}

/// The sorted, deduplicated union of sorted `x` and `y`. Caller owns it.
fn unionKeys(a: std.mem.Allocator, x: []const u64, y: []const u64) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len or j < y.len) {
        if (j == y.len or (i < x.len and x[i] < y[j])) {
            try out.append(a, x[i]);
            i += 1;
        } else if (i == x.len or y[j] < x[i]) {
            try out.append(a, y[j]);
            j += 1;
        } else {
            try out.append(a, x[i]);
            i += 1;
            j += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// True when every key of sorted `sub` is in sorted `super`.
fn isSubset(sub: []const u64, super: []const u64) bool {
    var j: usize = 0;
    for (sub) |key| {
        while (j < super.len and super[j] < key) j += 1;
        if (j == super.len or super[j] != key) return false;
        j += 1;
    }
    return true;
}

/// Which tree signature counts as built once a rebuild callback returns.
///
/// Each rebuild is bracketed by two snapshots of the watched tree: `start`,
/// taken right before the callback (the rebuild's trigger), and `post`,
/// right after it. Their per-path diff is the rebuild's `delta`: every path
/// that changed WHILE it ran — its own writes (a provider lifecycle hook
/// declares no outputs; a prebuild step may omit `.outputs`) and any edit
/// the user saved meanwhile, which the rebuild may or may not have read.
///
/// The rule:
///
/// - A rebuild whose `delta` is empty is built at its trigger (= `post`).
/// - A rebuild is SETTLED — `post` counts as built — only when it is a
///   follow-up (fired for exactly the previous rebuild's `post`: nothing
///   changed between the two) AND its `delta` is a subset of the previous
///   rebuild's `delta`. A self-writing hook rewrites the same paths on
///   every run, so its follow-up changes nothing new and settles: one extra
///   rebuild per edit, never a loop (Codex P2 on #420).
/// - Otherwise the rebuild is built at its trigger only, so `post` stays
///   unbuilt and fires one more rebuild. A path the user saves during a
///   rebuild — the first one or a follow-up — is a path that rebuild's
///   predecessor did not change, so the next rebuild is scheduled and
///   reads it (Codex P2 on #427: the follow-up used to accept its whole
///   `post`, an edit it had already compiled past included). That next
///   rebuild is itself a follow-up whose `delta` is the hook's writes
///   again, so the chain still ends.
///
/// Snapshots are `(size, mtime)` per path, so one case stays ambiguous: a
/// path changed during two CONSECUTIVE rebuilds (a user re-saving, during
/// the follow-up, the same file they also saved during the rebuild before
/// it) is indistinguishable from a hook rewriting its output, and is taken
/// as the follow-up's own write. Settling there is what bounds the hook.
///
/// Follow-up cap. A writer that changes a DIFFERENT path on every run (a
/// timestamp-named report: `{a}`, then `{b}`, then `{c}`) never satisfies
/// the subset rule, and used to rebuild and reload forever (Codex P2 on
/// #427). A chain — a rebuild plus the consecutive follow-ups fired for
/// exactly their predecessor's `post` — therefore also tracks the union of
/// every delta in it (`recent`) and the writers' `footprint`: the fewest
/// paths outside `recent` that any rebuild of the chain changed (a varying
/// writer's per-run count; an edit saved meanwhile only adds to it). From
/// the `follow_up_cap`-th follow-up on, a follow-up that changed no more
/// new-to-the-chain paths than that footprint is taken as the writers'
/// own and SETTLES on its `post`, logged once as `labelle: watch: settled
/// after N follow-up rebuilds triggered by build outputs`. One that changed
/// more — the writers' new path plus a source the user saved during it —
/// still fires one more rebuild, so the edit is read. A user edit saved
/// between rebuilds never makes a follow-up at all (the trigger is not the
/// previous `post`): it always rebuilds and starts a new chain. The count
/// cannot tell apart an edit, saved during a capped follow-up, that adds
/// no new-to-the-chain path beyond the footprint — a re-save of a path
/// already in `recent`, or one landing on a run where the writers changed
/// fewer new paths than usual — and takes it as a build output: the
/// ambiguity above, widened to the chain.
///
/// Ceiling. The `follow_up_ceiling`-th follow-up of a chain settles only
/// the chain's own output paths — those an earlier rebuild of the chain
/// changed (`recent`). A path outside that set (a source the user saved
/// while that follow-up ran, or a writer's new output: the two cannot be
/// told apart) stays pending: the tree it left is unbuilt, so one more
/// rebuild reads it, and that rebuild starts a FRESH chain rather than
/// counting as a ninth follow-up (Codex P2 on #427, cli#429: the ceiling
/// used to mark every path the final callback saw as built). As the last
/// bound, a chain started that way which reaches the ceiling again
/// settles whatever it changed, so no writer (one whose output count keeps
/// growing, say) can loop: it costs at most two chains.
const WatchBaseline = struct {
    /// Follow-ups after which a varying-path chain may settle (see above).
    const follow_up_cap: u32 = 2;
    /// Follow-ups after which a chain settles unconditionally.
    const follow_up_ceiling: u32 = 8;

    /// Signature of the last (attempted) build.
    applied: TreeSignature,
    /// Signature taken right after the last rebuild callback returned.
    post: ?TreeSignature = null,
    /// Sorted keys of the paths the last rebuild changed while it ran;
    /// `null` when unknown (none yet, or its snapshots were partial).
    /// Owned by `allocator`.
    delta: ?[]u64 = null,
    /// Consecutive follow-ups in the current chain.
    follow_ups: u32 = 0,
    /// Sorted union of the current chain's deltas; `null` when no chain is
    /// tracked (none yet, a delta was unknown, or it could not be stored).
    /// Owned by `allocator`.
    recent: ?[]u64 = null,
    /// Fewest new-to-the-chain paths any rebuild of the chain changed.
    footprint: usize = 0,
    /// Set by the `settle` that ended a chain by the follow-up cap: how many
    /// follow-ups it took (the watcher logs it); 0 otherwise.
    capped: u32 = 0,
    /// Set when a chain reached the ceiling with paths outside its own
    /// outputs: the next rebuild (fired for that pending tree) starts a
    /// fresh chain instead of counting as another follow-up.
    restart_chain: bool = false,
    /// The current chain was started by such a ceiling: reaching the
    /// ceiling again settles unconditionally (the last bound).
    after_ceiling: bool = false,
    allocator: std.mem.Allocator,

    fn deinit(self: *WatchBaseline) void {
        if (self.delta) |d| self.allocator.free(d);
        self.delta = null;
        self.dropChain();
    }

    fn dropChain(self: *WatchBaseline) void {
        self.forgetRecent();
        self.follow_ups = 0;
        self.footprint = 0;
    }

    /// Record a finished rebuild fired for `trigger` (its start-of-rebuild
    /// signature), with the tree at `post` once the callback returned and
    /// `delta` the sorted keys of the paths that changed in between
    /// (`null`: unknown, which never settles on `post`). Borrows `delta`.
    fn settle(self: *WatchBaseline, trigger: TreeSignature, post: TreeSignature, delta: ?[]const u64) void {
        const restarted = self.restart_chain;
        self.restart_chain = false;
        const follow_up = !restarted and if (self.post) |previous| trigger.eql(previous) else false;
        if (!follow_up) {
            self.dropChain();
            self.after_ceiling = restarted;
        }
        self.capped = 0;
        const by_rule = if (delta) |d|
            d.len == 0 or (follow_up and self.delta != null and isSubset(d, self.delta.?))
        else
            false;
        const settled = by_rule or self.chain(follow_up, delta);
        self.applied = if (settled) post else trigger;
        self.post = post;
        const kept: ?[]u64 = if (delta) |d| self.allocator.dupe(u64, d) catch null else null;
        if (self.delta) |old| self.allocator.free(old);
        self.delta = kept;
    }

    /// The follow-up cap (see the type's doc): count a follow-up, record
    /// `delta` in the chain, and return true when this follow-up settles by
    /// the cap or the ceiling. An unknown `delta` stops the chain's path
    /// tracking (the cap cannot judge it) but still counts toward the
    /// ceiling, where it is judged as changing paths outside the chain.
    fn chain(self: *WatchBaseline, follow_up: bool, delta: ?[]const u64) bool {
        if (follow_up) self.follow_ups +|= 1;
        const d = delta orelse {
            self.forgetRecent();
            return self.atCeiling(follow_up, null) == .settled;
        };
        const novel = if (self.recent) |r| countNovel(d, r) else d.len;
        if (follow_up and self.recent != null and self.follow_ups >= follow_up_cap and novel <= self.footprint) {
            self.capped = self.follow_ups;
            self.dropChain();
            return true;
        }
        switch (self.atCeiling(follow_up, d)) {
            .below => {},
            .settled => return true,
            .pending => return false,
        }
        const first = self.recent == null;
        const merged = unionKeys(self.allocator, self.recent orelse &.{}, d) catch {
            // Out of memory: stop tracking; only the ceiling still bounds it.
            self.forgetRecent();
            return false;
        };
        self.forgetRecent();
        self.recent = merged;
        self.footprint = if (first) novel else @min(self.footprint, novel);
        return false;
    }

    fn forgetRecent(self: *WatchBaseline) void {
        if (self.recent) |r| self.allocator.free(r);
        self.recent = null;
    }

    const Ceiling = enum { below, settled, pending };

    /// The ceiling (see the type's doc), judged BEFORE `delta` joins
    /// `recent`: a follow-up at the ceiling settles when every path it
    /// changed is one of the chain's own outputs, or when the chain was
    /// itself started by a ceiling (the last bound). Otherwise the chain
    /// ends with its `post` pending, and the rebuild that reads it starts a
    /// fresh chain.
    fn atCeiling(self: *WatchBaseline, follow_up: bool, delta: ?[]const u64) Ceiling {
        if (!follow_up or self.follow_ups < follow_up_ceiling) return .below;
        const own = if (delta) |d| if (self.recent) |r| isSubset(d, r) else false else false;
        const settled = own or self.after_ceiling;
        if (settled) self.capped = self.follow_ups;
        self.dropChain();
        self.after_ceiling = false;
        self.restart_chain = !settled;
        return if (settled) .settled else .pending;
    }

    /// True when `sig` differs from the last build (subject to debounce).
    fn unbuilt(self: WatchBaseline, sig: TreeSignature) bool {
        return !sig.eql(self.applied);
    }
};

/// True when a directory name should be skipped during the walk: any
/// dot-prefixed dir (`.labelle`, `.git`, `.zig-cache`, `.cache`) plus the
/// non-hidden build dirs in `watch_skip_dirs`.
fn skipWatchDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (watch_skip_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

/// Root a project-relative declared path (a `.prebuild` `.outputs` entry)
/// the same way `computeSignature`'s walk builds its paths, so the two can
/// be compared as plain strings. `resolve` collapses a leading `./` and
/// any `..` first — pure path math, no filesystem access — so
/// `"./assets/out.png"` and `"assets/out.png"` both match the walked
/// `<watch_dir>/assets/out.png`. Caller owns the result.
pub fn watchIgnorePath(
    allocator: std.mem.Allocator,
    watch_dir: []const u8,
    rel: []const u8,
) ![]const u8 {
    const norm = try std.fs.path.resolve(allocator, &.{rel});
    defer allocator.free(norm);
    return std.fs.path.join(allocator, &.{ watch_dir, norm });
}

/// True when `dir_path` is the root of its own git checkout: a linked
/// worktree, a submodule, or a nested clone.
///
/// Same marker probe as `labelle test`'s walker (#371): test for the
/// *existence* of a `.git` entry, never its kind — `git worktree add`
/// and submodules both write `.git` as a regular FILE holding a
/// `gitdir:` pointer. `skipWatchDir`'s dot rule only catches a checkout
/// whose own folder is dot-prefixed; a copy of the project parked under
/// a plain name (`worktrees/`, `vendor/`, `branches/`) would otherwise
/// fold thousands of unrelated files into the signature and make edits
/// on another branch trigger rebuilds here.
fn isNestedCheckout(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) bool {
    const marker = std.fs.path.join(allocator, &.{ dir_path, ".git" }) catch return false;
    defer allocator.free(marker);
    std.Io.Dir.cwd().access(io, marker, .{}) catch return false;
    return true;
}

/// True when a walked file path is one of the rebuild's own declared
/// outputs and must not contribute to the signature.
fn skipWatchFile(path: []const u8, ignore_files: []const []const u8) bool {
    for (ignore_files) |ig| {
        if (std.mem.eql(u8, path, ig)) return true;
    }
    return false;
}

/// Accumulate `dir_path`'s tree signature into `sig`. Best-effort: an
/// unreadable dir/file is skipped rather than fatal (a transient rename
/// mid-scan just shows up as a change on the next poll). Recurses into
/// subdirectories except those `skipWatchDir` rejects and those that are
/// nested git checkouts (#371).
fn computeSignature(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ignore_files: []const []const u8,
    sig: *TreeSignature,
) void {
    var snap: TreeSnapshot = .{ .sig = sig.* };
    walkTree(io, allocator, dir_path, ignore_files, &snap, false);
    sig.* = snap.sig;
}

/// The watched tree's `TreeSnapshot`: `computeSignature`'s walk, also
/// recording every file's `PathState` (sorted). `allocator` owns `paths`.
fn snapshotTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ignore_files: []const []const u8,
) TreeSnapshot {
    var snap: TreeSnapshot = .{};
    walkTree(io, allocator, dir_path, ignore_files, &snap, true);
    snap.sort();
    return snap;
}

fn walkTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ignore_files: []const []const u8,
    snap: *TreeSnapshot,
    per_path: bool,
) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind == .directory) {
            if (skipWatchDir(entry.name)) continue;
            const sub = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
            defer allocator.free(sub);
            if (isNestedCheckout(io, allocator, sub)) continue;
            walkTree(io, allocator, sub, ignore_files, snap, per_path);
        } else if (entry.kind == .file) {
            const fpath = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
            defer allocator.free(fpath);
            if (skipWatchFile(fpath, ignore_files)) continue;
            const st = std.Io.Dir.cwd().statFile(io, fpath, .{}) catch continue;
            if (per_path) {
                snap.record(allocator, fpath, st.size, st.mtime.nanoseconds);
            } else {
                snap.sig.mix(fpath, st.size, st.mtime.nanoseconds);
            }
        }
    }
}

/// Pure debounce decision: fire a rebuild once the tree has held a new,
/// unbuilt signature steady for at least `quiet_polls` consecutive polls.
/// Extracted for unit testing the burst-coalescing logic without threads.
fn shouldRebuild(unbuilt: bool, stable_polls: u32, quiet_polls: u32) bool {
    const need = if (quiet_polls == 0) 1 else quiet_polls;
    return unbuilt and stable_polls >= need;
}

/// Splice `reload_client_js` into `html` just before `</body>` (or append
/// it when there's no body tag). Caller owns the returned buffer.
fn injectReloadScript(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const marker = "</body>";
    if (std.mem.lastIndexOf(u8, html, marker)) |idx| {
        var out = try allocator.alloc(u8, html.len + reload_client_js.len);
        @memcpy(out[0..idx], html[0..idx]);
        @memcpy(out[idx..][0..reload_client_js.len], reload_client_js);
        @memcpy(out[idx + reload_client_js.len ..], html[idx..]);
        return out;
    }
    return std.mem.concat(allocator, u8, &.{ html, reload_client_js });
}

/// Watcher thread body: poll the tree, debounce, rebuild, bump version.
/// Runs until `state.stop` is set. A rebuild failure is surfaced in the
/// terminal but keeps the loop (and server) alive; `applied` still advances
/// so we don't respin on the same broken tree — a later edit retriggers.
fn watchLoop(io: std.Io, cfg: WatchConfig, state: *WatchState) void {
    var scan_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scan_arena.deinit();

    // `baseline.applied` = signature of the last (attempted) build (see
    // `WatchBaseline` for how a self-writing rebuild settles it). `last` =
    // signature seen on the previous poll — used to detect a burst still in
    // flight.
    var initial = TreeSignature{};
    computeSignature(io, scan_arena.allocator(), cfg.watch_dir, cfg.ignore_files, &initial);
    _ = scan_arena.reset(.retain_capacity);
    var baseline: WatchBaseline = .{ .applied = initial, .allocator = std.heap.page_allocator };
    defer baseline.deinit();
    // The two per-path snapshots bracketing each rebuild; reset after it.
    var rebuild_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer rebuild_arena.deinit();
    var last = initial;
    var stable_polls: u32 = 0;

    const interval = std.Io.Duration.fromMilliseconds(@intCast(cfg.poll_interval_ms));

    while (!state.stop.load(.acquire)) {
        io.sleep(interval, .awake) catch return;
        if (state.stop.load(.acquire)) return;

        var sig = TreeSignature{};
        computeSignature(io, scan_arena.allocator(), cfg.watch_dir, cfg.ignore_files, &sig);
        _ = scan_arena.reset(.retain_capacity);

        if (!sig.eql(last)) {
            // Tree still changing — reset the quiet counter (debounce).
            last = sig;
            stable_polls = 0;
            continue;
        }
        stable_polls +|= 1;
        if (!shouldRebuild(baseline.unbuilt(sig), stable_polls, cfg.quiet_polls)) continue;

        std.debug.print("labelle: change detected — rebuilding WASM...\n", .{});
        // The tree as this rebuild starts on it, and as the callback leaves
        // it: their per-path diff is what changed while it ran
        // (`WatchBaseline`).
        const ra = rebuild_arena.allocator();
        const start = snapshotTree(io, ra, cfg.watch_dir, cfg.ignore_files);
        const ok = cfg.rebuild_fn(cfg.rebuild_ctx);
        const post = snapshotTree(io, ra, cfg.watch_dir, cfg.ignore_files);
        const delta: ?[]const u64 = if (start.complete and post.complete)
            changedPaths(ra, start.paths.items, post.paths.items) catch null
        else
            null;
        baseline.settle(start.sig, post.sig, delta);
        if (baseline.capped != 0) std.debug.print("labelle: watch: settled after {d} follow-up rebuilds triggered by build outputs\n", .{baseline.capped});
        _ = rebuild_arena.reset(.retain_capacity);
        stable_polls = 0;
        if (ok) {
            _ = state.version.fetchAdd(1, .release);
            std.debug.print("labelle: rebuild ok — reloading connected browsers\n", .{});
        } else {
            std.debug.print("labelle: rebuild failed — see errors above; server still running\n", .{});
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

/// A distinct synthetic tree signature per label, for the baseline tests.
fn testSig(label: []const u8) TreeSignature {
    var sig = TreeSignature{};
    sig.mix(label, label.len, 0);
    return sig;
}

/// A scripted rebuild for the baseline tests: the sorted path keys that
/// changed while it ran.
fn testDelta(comptime paths: []const []const u8) [paths.len]u64 {
    var keys: [paths.len]u64 = undefined;
    for (paths, 0..) |path, i| keys[i] = pathKey(path);
    std.mem.sort(u64, &keys, {}, std.sort.asc(u64));
    return keys;
}

test "watch baseline: a rebuild that rewrites its own output settles after one follow-up" {
    // A hook that rewrites `assets/out.png` on every run: each callback
    // leaves the tree at a fresh signature, with that one path changed.
    const hook = testDelta(&.{"assets/out.png"});
    const edited = testSig("user edit");
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    try std.testing.expect(b.unbuilt(edited));
    // Rebuild 1, for the user's edit; its hook writes -> `write1`.
    const write1 = testSig("hook write 1");
    b.settle(edited, write1, &hook);
    // The hook's write is unbuilt: one follow-up rebuild fires.
    try std.testing.expect(b.unbuilt(write1));
    // The follow-up's hook writes the same path again -> `write2`: nothing
    // its predecessor did not change, so it settles on `write2`.
    const write2 = testSig("hook write 2");
    b.settle(write1, write2, &hook);
    try std.testing.expect(!b.unbuilt(write2));
    // The mechanism: it is the follow-up's delta that settles it — the
    // same rebuild with an unknown delta leaves the hook's write pending.
    var unknown: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer unknown.deinit();
    unknown.settle(edited, write1, &hook);
    unknown.settle(write1, write2, null);
    try std.testing.expect(unknown.unbuilt(write2));
}

test "watch baseline: an edit saved during the follow-up rebuild stays pending (Codex P2 on #427)" {
    const hook = testDelta(&.{"assets/out.png"});
    // The follow-up changed the hook's path AND a source the user saved
    // after the follow-up had read it.
    const hook_and_edit = testDelta(&.{ "assets/out.png", "src/main.zig" });
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    const edited = testSig("user edit");
    const write1 = testSig("hook write 1");
    b.settle(edited, write1, &hook);
    try std.testing.expect(b.unbuilt(write1));
    // Follow-up (fired for `write1`), during which the user saves main.zig.
    const write2_with_edit = testSig("hook write 2 + edit");
    b.settle(write1, write2_with_edit, &hook_and_edit);
    // Not settled: main.zig is new relative to the previous rebuild's
    // writes, so the tree the follow-up left is still unbuilt and fires
    // one more rebuild. The old rule accepted it and lost the edit.
    try std.testing.expect(b.unbuilt(write2_with_edit));
    try std.testing.expect(b.applied.eql(write1));
    // That rebuild (fired for exactly the follow-up's post) only rewrites
    // the hook's path again: a subset, so the chain ends here — (a) still
    // holds with the edit in it, after exactly one more rebuild.
    const write3 = testSig("hook write 3");
    b.settle(write2_with_edit, write3, &hook);
    try std.testing.expect(!b.unbuilt(write3));
}

test "watch baseline: a scripted session never settles past an unread edit and never loops" {
    // A self-writing hook plus user saves landing at every point of the
    // chain. Each step: the trigger the watcher fired for, and what changed
    // while that rebuild ran. `must_rebuild` is whether the tree it left
    // is (correctly) still unbuilt.
    const Step = struct { trigger: []const u8, post: []const u8, delta: []const u64, must_rebuild: bool };
    const hook = testDelta(&.{"gen/out.zig"});
    const hook_a = testDelta(&.{ "gen/out.zig", "src/a.zig" });
    const hook_b = testDelta(&.{ "gen/out.zig", "src/b.zig" });
    const none = testDelta(&.{});
    const a_only = testDelta(&.{"src/a.zig"});
    const script = [_]Step{
        // Edit 1; the hook writes; a.zig saved meanwhile -> follow-up.
        .{ .trigger = "e1", .post = "p1", .delta = &hook_a, .must_rebuild = true },
        // Follow-up; b.zig saved during it -> one more.
        .{ .trigger = "p1", .post = "p2", .delta = &hook_b, .must_rebuild = true },
        // One more: only the hook's path -> settled.
        .{ .trigger = "p2", .post = "p3", .delta = &hook, .must_rebuild = false },
        // A later ordinary edit, with a save of a.zig during it and no
        // self-write -> the next rebuild reads a.zig...
        .{ .trigger = "e2", .post = "p4", .delta = &a_only, .must_rebuild = true },
        // ...and writes nothing: built.
        .{ .trigger = "p4", .post = "p4", .delta = &none, .must_rebuild = false },
    };
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    for (script) |step| {
        b.settle(testSig(step.trigger), testSig(step.post), step.delta);
        try std.testing.expectEqual(step.must_rebuild, b.unbuilt(testSig(step.post)));
    }
}

test "watch baseline: a hook writing a different path each run settles at the follow-up cap (Codex P2 on #427)" {
    // A timestamp-named report: every run writes a NEW path, so no
    // follow-up's delta is a subset of its predecessor's.
    const r1 = testDelta(&.{"reports/1.txt"});
    const r2 = testDelta(&.{"reports/2.txt"});
    const r3 = testDelta(&.{"reports/3.txt"});
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    b.settle(testSig("edit"), testSig("p1"), &r1);
    try std.testing.expect(b.unbuilt(testSig("p1")));
    // Follow-up 1: below the cap, still pending.
    b.settle(testSig("p1"), testSig("p2"), &r2);
    try std.testing.expect(b.unbuilt(testSig("p2")));
    try std.testing.expectEqual(@as(u32, 0), b.capped);
    // Follow-up 2 reaches the cap: one new path, the writer's footprint,
    // so it settles — and it was the cap that did it, not the subset rule.
    try std.testing.expect(!isSubset(&r3, &r2));
    b.settle(testSig("p2"), testSig("p3"), &r3);
    try std.testing.expect(!b.unbuilt(testSig("p3")));
    try std.testing.expectEqual(WatchBaseline.follow_up_cap, b.capped);
    // The chain is over: the next edit starts a fresh one, with the full
    // allowance again.
    b.settle(testSig("edit 2"), testSig("p4"), &r1);
    try std.testing.expectEqual(@as(u32, 0), b.capped);
    try std.testing.expect(b.unbuilt(testSig("p4")));
    b.settle(testSig("p4"), testSig("p5"), &r2);
    try std.testing.expect(b.unbuilt(testSig("p5")));
}

test "watch baseline: an edit saved during a capped follow-up still fires one more rebuild" {
    const r1 = testDelta(&.{"reports/1.txt"});
    const r2 = testDelta(&.{"reports/2.txt"});
    // At the cap, the writer's new report AND a source the user saved
    // while that follow-up ran: more new paths than the writer's footprint.
    const r3_edit = testDelta(&.{ "reports/3.txt", "src/main.zig" });
    const r4 = testDelta(&.{"reports/4.txt"});
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    b.settle(testSig("edit"), testSig("p1"), &r1);
    b.settle(testSig("p1"), testSig("p2"), &r2);
    b.settle(testSig("p2"), testSig("p3"), &r3_edit);
    // Not settled: main.zig is read by one more rebuild.
    try std.testing.expect(b.unbuilt(testSig("p3")));
    try std.testing.expectEqual(@as(u32, 0), b.capped);
    // That rebuild only writes the next report: settled past the cap.
    b.settle(testSig("p3"), testSig("p4"), &r4);
    try std.testing.expect(!b.unbuilt(testSig("p4")));
    try std.testing.expectEqual(@as(u32, 3), b.capped);
}

test "watch baseline: an edit saved between capped-chain rebuilds always rebuilds and restarts the chain" {
    const r1 = testDelta(&.{"reports/1.txt"});
    const r2 = testDelta(&.{"reports/2.txt"});
    const r3 = testDelta(&.{"reports/3.txt"});
    const r4 = testDelta(&.{"reports/4.txt"});
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    b.settle(testSig("edit"), testSig("p1"), &r1);
    b.settle(testSig("p1"), testSig("p2"), &r2);
    // The user saves after follow-up 1 returned: the tree the watcher
    // fires for is not `p2`, so this is no follow-up and cannot settle...
    b.settle(testSig("p2 + edit"), testSig("p3"), &r3);
    try std.testing.expect(b.unbuilt(testSig("p3")));
    try std.testing.expectEqual(@as(u32, 0), b.follow_ups);
    // ...and its follow-up is the new chain's first, below the cap.
    b.settle(testSig("p3"), testSig("p4"), &r4);
    try std.testing.expect(b.unbuilt(testSig("p4")));
    try std.testing.expectEqual(@as(u32, 1), b.follow_ups);
}

/// Drives a writer whose output count keeps growing (run `i` writes `i + 1`
/// paths nobody wrote before): never within the chain's footprint, so only
/// the ceiling can end its chains.
const GrowingWriter = struct {
    b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator },
    keys: [512]u64 = undefined,
    next: usize = 0,
    run: usize = 0,
    trigger: TreeSignature = testSig("edit"),

    fn init(self: *GrowingWriter) void {
        for (&self.keys, 0..) |*k, i| k.* = 1_000_000 + i;
    }

    fn postOf(run: usize) TreeSignature {
        var sig = TreeSignature{};
        sig.mix("post", run, 0);
        return sig;
    }

    /// One rebuild; `extra` is a path saved while it ran (or null).
    /// Returns its post signature.
    fn step(self: *GrowingWriter, extra: ?u64) !TreeSignature {
        var delta: [64]u64 = undefined;
        const count = self.run + 1;
        @memcpy(delta[0..count], self.keys[self.next .. self.next + count]);
        self.next += count;
        var len = count;
        if (extra) |key| {
            delta[len] = key;
            len += 1;
        }
        std.mem.sort(u64, delta[0..len], {}, std.sort.asc(u64));
        const post = postOf(self.run);
        self.b.settle(self.trigger, post, delta[0..len]);
        self.trigger = post;
        self.run += 1;
        return post;
    }
};

test "watch baseline: a writer whose output keeps growing settles at the second ceiling" {
    var w: GrowingWriter = .{};
    w.init();
    defer w.b.deinit();
    // The first chain: the rebuild plus `follow_up_ceiling` follow-ups.
    // At its ceiling the writer's new paths are outside the chain's own
    // outputs, so the tree stays pending and the chain restarts.
    while (w.run < WatchBaseline.follow_up_ceiling) {
        try std.testing.expect(w.b.unbuilt(try w.step(null)));
    }
    const first_ceiling = try w.step(null);
    try std.testing.expect(w.b.unbuilt(first_ceiling));
    try std.testing.expectEqual(@as(u32, 0), w.b.capped);
    // The fresh chain started by that ceiling reaches it again: the last
    // bound settles it, so the writer cannot loop.
    var follow_up: u32 = 0;
    while (follow_up < WatchBaseline.follow_up_ceiling) : (follow_up += 1) {
        try std.testing.expect(w.b.unbuilt(try w.step(null)));
        try std.testing.expectEqual(follow_up, w.b.follow_ups);
    }
    const second_ceiling = try w.step(null);
    try std.testing.expect(!w.b.unbuilt(second_ceiling));
    try std.testing.expectEqual(WatchBaseline.follow_up_ceiling, w.b.capped);
}

test "watch baseline: a source edit saved during the ceiling follow-up stays pending (cli#429)" {
    var w: GrowingWriter = .{};
    w.init();
    defer w.b.deinit();
    while (w.run < WatchBaseline.follow_up_ceiling) _ = try w.step(null);
    try std.testing.expectEqual(WatchBaseline.follow_up_ceiling - 1, w.b.follow_ups);
    // The ceiling follow-up: the writer's paths plus a source the user
    // saved while it ran. Not settled — the old ceiling marked the whole
    // post built and the edit was never compiled.
    const trigger = w.trigger;
    const with_edit = try w.step(pathKey("src/main.zig"));
    try std.testing.expect(w.b.unbuilt(with_edit));
    try std.testing.expect(w.b.applied.eql(trigger));
    try std.testing.expectEqual(@as(u32, 0), w.b.capped);
    // The rebuild that reads it is fired for exactly that post, yet starts
    // a fresh chain instead of counting as a ninth follow-up.
    _ = try w.step(null);
    try std.testing.expectEqual(@as(u32, 0), w.b.follow_ups);
    try std.testing.expect(w.b.after_ceiling);
}

test "watch baseline: a ceiling follow-up that changed only the chain's own outputs settles" {
    // `atCeiling` judged directly: every path already in the chain's
    // `recent` set settles; one outside it leaves the tree pending.
    const own = testDelta(&.{ "gen/a.zig", "gen/b.zig" });
    const outside = testDelta(&.{ "gen/a.zig", "src/main.zig" });
    for ([_]struct { delta: []const u64, settles: bool }{
        .{ .delta = own[0..1], .settles = true },
        .{ .delta = &outside, .settles = false },
    }) |case| {
        var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
        defer b.deinit();
        b.recent = try std.testing.allocator.dupe(u64, &own);
        b.follow_ups = WatchBaseline.follow_up_ceiling;
        const verdict = b.atCeiling(true, case.delta);
        try std.testing.expectEqual(if (case.settles) WatchBaseline.Ceiling.settled else .pending, verdict);
        try std.testing.expectEqual(!case.settles, b.restart_chain);
    }
}

test "watch baseline: an edit saved during an ordinary rebuild still fires the next one" {
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    const first = testSig("edit 1");
    // A rebuild that writes nothing into the tree; the user saves again
    // while it runs, so the tree after the callback is `second`.
    const second = testSig("edit 2");
    const edit = testDelta(&.{"src/main.zig"});
    b.settle(first, second, &edit);
    try std.testing.expect(b.unbuilt(second));
    // That rebuild (fired for `second`) writes nothing: settled on it.
    b.settle(second, second, &.{});
    try std.testing.expect(!b.unbuilt(second));
    // A later edit is an ordinary trigger again: built at the trigger, so
    // a save during THIS rebuild is not swallowed either.
    const third = testSig("edit 3");
    const fourth = testSig("edit 4");
    b.settle(third, fourth, &edit);
    try std.testing.expect(b.unbuilt(fourth));
}

test "changedPaths: added, removed and changed paths, by key" {
    const a = std.testing.allocator;
    var before: TreeSnapshot = .{};
    defer before.paths.deinit(a);
    before.record(a, "keep", 1, 1);
    before.record(a, "edit", 1, 1);
    before.record(a, "gone", 1, 1);
    before.sort();
    var after: TreeSnapshot = .{};
    defer after.paths.deinit(a);
    after.record(a, "keep", 1, 1);
    after.record(a, "edit", 1, 2);
    after.record(a, "new", 1, 1);
    after.sort();
    const delta = try changedPaths(a, before.paths.items, after.paths.items);
    defer a.free(delta);
    const expected = testDelta(&.{ "edit", "gone", "new" });
    try std.testing.expectEqualSlices(u64, &expected, delta);
    try std.testing.expect(isSubset(&testDelta(&.{"edit"}), delta));
    try std.testing.expect(!isSubset(&testDelta(&.{ "edit", "keep" }), delta));
    // The snapshot's signature is the one the polls compute.
    var sig = TreeSignature{};
    sig.mix("keep", 1, 1);
    sig.mix("edit", 1, 2);
    sig.mix("new", 1, 1);
    try std.testing.expect(sig.eql(after.sig));
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

test "resolveTarget: rejects backslash (Windows separator traversal)" {
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
        handleConnection(io, alloc, stream, web_dir, project_web_dir, watch_state) catch {};
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

// ── Watch / live-reload tests (cli#208) ──────────────────────────────

test "shouldRebuild: fires only after quiet_polls stable ticks with unbuilt changes" {
    // Not yet stable enough.
    try std.testing.expect(!shouldRebuild(true, 1, 2));
    // Stable long enough + unbuilt → fire.
    try std.testing.expect(shouldRebuild(true, 2, 2));
    try std.testing.expect(shouldRebuild(true, 5, 2));
    // Nothing unbuilt → never fire, however long it's been quiet.
    try std.testing.expect(!shouldRebuild(false, 9, 2));
}

test "shouldRebuild: quiet_polls of 0 is clamped to 1 (fires on first stable tick)" {
    try std.testing.expect(shouldRebuild(true, 1, 0));
    try std.testing.expect(!shouldRebuild(false, 1, 0));
}

test "skipWatchDir: skips dot-dirs and build output, keeps source dirs" {
    try std.testing.expect(skipWatchDir(".labelle"));
    try std.testing.expect(skipWatchDir(".git"));
    try std.testing.expect(skipWatchDir(".zig-cache"));
    try std.testing.expect(skipWatchDir("zig-out"));
    try std.testing.expect(skipWatchDir("zig-pkg"));
    try std.testing.expect(!skipWatchDir("scenes"));
    try std.testing.expect(!skipWatchDir("prefabs"));
    try std.testing.expect(!skipWatchDir("assets"));
    try std.testing.expect(!skipWatchDir("src"));
}

test "injectReloadScript: splices before </body>" {
    const alloc = std.testing.allocator;
    const html = "<html><body><canvas></canvas></body></html>";
    const out = try injectReloadScript(alloc, html);
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
    const out = try injectReloadScript(alloc, html);
    defer alloc.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "<h1>bare fragment</h1>"));
    try std.testing.expect(std.mem.indexOf(u8, out, "__labelle_livereload") != null);
}

test "computeSignature: changes on add, edit, and remove" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });

    var base = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &base);
    try std.testing.expectEqual(@as(u64, 1), base.file_count);

    // Add a file → count + digest change.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "twelve!" });
    var after_add = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &after_add);
    try std.testing.expect(!base.eql(after_add));
    try std.testing.expectEqual(@as(u64, 2), after_add.file_count);

    // Edit a file in place, changing its SIZE. Keeping the file count the
    // same, the size component of the per-file digest flips regardless of
    // mtime — deterministic on every platform (no dependency on the OS
    // giving the edited file a distinguishable mtime, which is coarse/
    // coalesced on Windows).
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "twelve!-longer" });
    var after_edit = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &after_edit);
    try std.testing.expectEqual(after_add.file_count, after_edit.file_count);
    try std.testing.expect(!after_add.eql(after_edit));

    // Remove a file → back down to one entry, different from every prior sig.
    try tmp.dir.deleteFile(io, "b.txt");
    var after_rm = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &after_rm);
    try std.testing.expectEqual(@as(u64, 1), after_rm.file_count);
    try std.testing.expect(!after_rm.eql(after_add));
}

test "TreeSignature: a same-size edit to a NON-newest file still flips the signature" {
    // Regression for the codex finding: a summed-size + single-newest-mtime
    // signature misses a same-size edit to a file that isn't the newest.
    // Two files; the second (mtime 200) is the newest. Edit the first to the
    // SAME size (10 bytes) with a new mtime that is still older than the
    // newest (150 < 200) — total size (30) and the newest mtime (200) are
    // both unchanged, so the old scheme would report "no change". The
    // per-file digest catches it.
    var before = TreeSignature{};
    before.mix("old.txt", 10, 100);
    before.mix("new.txt", 20, 200);

    var after = TreeSignature{};
    after.mix("old.txt", 10, 150); // same size, newer mtime, still not newest
    after.mix("new.txt", 20, 200);

    try std.testing.expectEqual(before.file_count, after.file_count);
    try std.testing.expect(!before.eql(after));
}

test "computeSignature: a same-size in-place edit triggers a rebuild" {
    // Windows FS mtime granularity/update timing makes real-FS same-size-edit
    // detection non-deterministic in CI; the deterministic coverage is the
    // in-memory `TreeSignature.mix` test above.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    // Two files; `b.txt` is written last (newest). Editing the OLDER `a.txt`
    // to the same length is the case the naive signature missed.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "aaaa" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "bbbb" });

    var applied = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &applied);

    // Same 4-byte length, different content → only the mtime moves. On
    // macOS/Linux the write bumps the file's mtime to a distinguishable
    // value, so the (path,size,mtime) digest flips.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "AAAA" });
    var now = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &now);

    try std.testing.expectEqual(applied.file_count, now.file_count);
    try std.testing.expect(!applied.eql(now));
    // …and that unbuilt delta drives a rebuild once it's held steady.
    try std.testing.expect(shouldRebuild(!now.eql(applied), 2, 2));
}

test "computeSignature: skips .labelle build-output dir (no self-trigger)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "scene.zon", .data = "source" });
    var before = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &before);

    // Simulate a rebuild writing into .labelle/ — the signature must not move.
    try tmp.dir.createDirPath(io, ".labelle/raylib_wasm");
    try tmp.dir.writeFile(io, .{ .sub_path = ".labelle/raylib_wasm/out.wasm", .data = "artifact" });
    var after = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &after);
    try std.testing.expect(before.eql(after));
}

test "handleConnection: --watch answers the version endpoint and injects the reload client" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{
        .sub_path = "index.html",
        .data = "<html><body><canvas id=game></canvas></body></html>",
    });

    var wstate = WatchState{};
    _ = wstate.version.fetchAdd(7, .release);

    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    const port = bound.port;
    defer server.deinit(io);

    const t = try std.Thread.spawn(.{}, testServeNWatch, .{ io, alloc, &server, web_dir, @as(?[]const u8, null), @as(usize, 2), &wstate });
    defer t.join();

    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const Case = struct { target: []const u8, want: []const u8 };
    for ([_]Case{
        // Version endpoint reflects the current build version.
        .{ .target = "/__labelle_livereload", .want = "7" },
        // The root HTML gets the reload client spliced in.
        .{ .target = "/", .want = "__labelle_livereload" },
    }) |case| {
        const s = try peer.connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [512]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{case.target});
        try w.interface.flush();

        var rbuf: [8192]u8 = undefined;
        var r = s.reader(io, &rbuf);
        const resp = try r.interface.allocRemaining(alloc, .unlimited);
        defer alloc.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, case.want) != null);
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

// The watch-mode double rebuild (cli#355 review round 2): a prebuild hook
// regenerates a non-hidden output, `watchLoop` records the signature it
// captured BEFORE the callback, and the next poll sees the hook's own
// write as a fresh change — a second full generate/compile/browser-reload
// for a step that is now up to date.
test "computeSignature: a declared prebuild output does not move the signature" {
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp.dir.realPath(io, &buf)];
    const alloc = std.testing.allocator;

    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "game.zig", .data = "const a = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/out.png", .data = "v1" });

    const ignored = try watchIgnorePath(alloc, dir_path, "assets/out.png");
    defer alloc.free(ignored);
    const ignore_files = [_][]const u8{ignored};

    var before = TreeSignature{};
    computeSignature(io, alloc, dir_path, &ignore_files, &before);

    // The hook regenerates its declared output — a different size AND a
    // later mtime, which is what the naive signature keyed on.
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/out.png", .data = "v2-regenerated" });

    var after = TreeSignature{};
    computeSignature(io, alloc, dir_path, &ignore_files, &after);
    try std.testing.expect(before.eql(after));

    // ...while an edit to a watched SOURCE still fires.
    try tmp.dir.writeFile(io, .{ .sub_path = "game.zig", .data = "const a = 2222;" });
    var edited = TreeSignature{};
    computeSignature(io, alloc, dir_path, &ignore_files, &edited);
    try std.testing.expect(!before.eql(edited));
    // And without the exclusion the regeneration DOES move it — the bug.
    var unfiltered_before = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &unfiltered_before);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/out.png", .data = "v3-regenerated-again" });
    var unfiltered_after = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &unfiltered_after);
    try std.testing.expect(!unfiltered_before.eql(unfiltered_after));
}

test "watchIgnorePath: roots a declared output the way the walk builds paths" {
    // POSIX-only: the expected strings spell the separator. The behavior
    // under test (a leading `./` must still match the walked path) is
    // separator-agnostic, and the tree-level test above covers it on
    // every platform.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const plain = try watchIgnorePath(alloc, "/proj", "assets/out.png");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("/proj/assets/out.png", plain);

    // A leading `./` in the declaration must still match the walked path.
    const dotted = try watchIgnorePath(alloc, "/proj", "./assets/out.png");
    defer alloc.free(dotted);
    try std.testing.expectEqualStrings("/proj/assets/out.png", dotted);
}

test "skipWatchFile: matches only the declared outputs" {
    const ignore_files = [_][]const u8{ "/proj/assets/out.png", "/proj/scripts/table.zig" };
    try std.testing.expect(skipWatchFile("/proj/assets/out.png", &ignore_files));
    try std.testing.expect(skipWatchFile("/proj/scripts/table.zig", &ignore_files));
    try std.testing.expect(!skipWatchFile("/proj/assets/out.json", &ignore_files));
    try std.testing.expect(!skipWatchFile("/proj/game.zig", &ignore_files));
    try std.testing.expect(!skipWatchFile("/proj/assets/out.png", &.{}));
}

// #371: the same nested-checkout gap `labelle test` had. `skipWatchDir`'s
// dot rule only hides a checkout whose own folder starts with a dot; a
// worktree parked under a plain name folded a whole second copy of the
// project into the signature, so edits on an unrelated branch fired
// rebuilds here. The fixtures write the `.git` markers by hand (no `git`
// invocation) so they run on the ubuntu and windows CI runners too.
test "computeSignature: nested git checkouts are pruned, ordinary dirs are not" {
    const io = config.globalIo();
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.writeFile(io, .{ .sub_path = "game.zig", .data = "const a = 1;" });

    var base = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &base);
    try std.testing.expectEqual(@as(u64, 1), base.file_count);

    // A linked worktree: `.git` is a FILE holding a `gitdir:` pointer,
    // so a kind check would miss it.
    try tmp.dir.createDirPath(io, "verify-821/libs/ui_kit");
    try tmp.dir.writeFile(io, .{ .sub_path = "verify-821/libs/ui_kit/root.zig", .data = "stale" });
    try tmp.dir.writeFile(io, .{ .sub_path = "verify-821/.git", .data = "gitdir: /somewhere\n" });

    var with_worktree = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &with_worktree);
    try std.testing.expect(base.eql(with_worktree));

    // A plain nested clone: `.git` is a DIRECTORY. Pruned too.
    try tmp.dir.createDirPath(io, "vendor/other/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/other/main.zig", .data = "stale" });

    var with_clone = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &with_clone);
    try std.testing.expect(base.eql(with_clone));

    // ...but an ordinary directory that merely *looks* like a worktree
    // parent still counts: the prune keys on the marker, not the name.
    try tmp.dir.createDirPath(io, "worktrees");
    try tmp.dir.writeFile(io, .{ .sub_path = "worktrees/helper.zig", .data = "real source" });

    var with_plain_dir = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &with_plain_dir);
    try std.testing.expect(!base.eql(with_plain_dir));
    try std.testing.expectEqual(@as(u64, 2), with_plain_dir.file_count);
}

test "isNestedCheckout: keys on the .git marker's existence, not its kind" {
    const io = config.globalIo();
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: /elsewhere\n" });
    try tmp.dir.createDirPath(io, "clone/.git");
    try tmp.dir.createDirPath(io, "plain/src");

    for ([_]struct { name: []const u8, want: bool }{
        .{ .name = "wt", .want = true },
        .{ .name = "clone", .want = true },
        .{ .name = "plain", .want = false },
    }) |case| {
        const p = try std.fs.path.join(alloc, &.{ root, case.name });
        defer alloc.free(p);
        try std.testing.expectEqual(case.want, isNestedCheckout(io, alloc, p));
    }
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
