//! Loopback helpers shared by the serve modules' tests.
const std = @import("std");
const watch = @import("../watch.zig");
const WatchState = watch.State;
const handleConnection = @import("request.zig").handleConnection;

/// Accept `n` connections then return — the test side of the loop in
/// `serveAndOpen`. Lives in a thread so the test's request side can
/// drive the real `std.Io.net` round-trip in-process.
pub fn testServeN(
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
pub fn testServeNWatch(
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
pub fn testBindFreePort(io: std.Io) ?struct { server: std.Io.net.Server, port: u16 } {
    var port: u16 = 49500;
    while (port < 49600) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const server = addr.listen(io, .{ .reuse_address = true }) catch continue;
        return .{ .server = server, .port = port };
    }
    return null;
}

/// Issue a single `GET /` over loopback and return the full response.
/// Caller frees the result.
pub fn testRootRequest(
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

/// One GET through `handleConnection` on its own thread; returns the response.
pub fn testGet(io: std.Io, alloc: std.mem.Allocator, server: *std.Io.net.Server, port: u16, web_dir: []const u8, state: ?*WatchState, target: []const u8) ![]u8 {
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

pub fn testBody(resp: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return resp;
    return resp[at + 4 ..];
}
