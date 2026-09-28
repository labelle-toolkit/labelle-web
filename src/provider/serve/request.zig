//! One HTTP request: root resolution, containment checks, the live-reload
//! endpoint and the HTML injections.
const std = @import("std");
const builtin = @import("builtin");
const watch = @import("../watch.zig");
const WatchState = watch.State;
const mimeFor = @import("route.zig").mimeFor;
const resolvePath = @import("route.zig").resolvePath;
const injectFirst = @import("inject.zig").injectFirst;
const injectReloadScript = @import("inject.zig").injectReloadScript;
const livereload_rel = @import("inject.zig").livereload_rel;
const runEnvScript = @import("inject.zig").runEnvScript;
const testBindFreePort = @import("test_support.zig").testBindFreePort;
const testBody = @import("test_support.zig").testBody;
const testGet = @import("test_support.zig").testGet;
const testRootRequest = @import("test_support.zig").testRootRequest;
const testServeN = @import("test_support.zig").testServeN;
const testServeNWatch = @import("test_support.zig").testServeNWatch;

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
pub fn handleConnection(
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
        if (at_root and std.ascii.eqlIgnoreCase(std.fs.path.basename(actual), @import("../assets.zig").state_file)) {
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

    // Served HTML gets the `labelle run` options right after its doctype
    // (so first in <head>, per the HTML parser) and, in a
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

test "handleConnection: run options reach the page right after the doctype; the endpoint stays a file outside watch" {
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
    try std.testing.expect(std.mem.startsWith(u8, page[std.mem.indexOf(u8, page, "<!doctype html>").? + "<!doctype html>".len ..], "<script>"));
    try std.testing.expect(env_at < std.mem.indexOf(u8, page, "<html>").?);
    try std.testing.expect(env_at < std.mem.indexOf(u8, page, "var Module={}").?);
    try std.testing.expect(std.mem.indexOf(u8, page, "location.reload") == null);
    const asset = try testGet(io, alloc, &server, bound.port, root, &wstate, "/__labelle_livereload");
    defer alloc.free(asset);
    try std.testing.expectEqualStrings("asset", testBody(asset));
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
