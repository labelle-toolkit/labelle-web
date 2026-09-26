//! CLI provider entry point. Commands and hooks share shell staging and packaging.
const std = @import("std");
const contract = @import("provider/contract.zig");
const config = @import("provider/config.zig");
const assets = @import("provider/assets.zig");
const exporter = @import("provider/export.zig");
const server = @import("provider/serve.zig");
const Settings = struct {
    build_dir: ?[]const u8 = null,
    port: u16 = 8080,
    open_browser: bool = true,
};
const Options = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    port: ?u16 = null,
    no_open: bool = false,
    zip: bool = false,
    platform: exporter.Platform = .none,
};

pub fn main(init: std.process.Init) !u8 {
    config.io = init.io;
    execute(init) catch |err| {
        std.debug.print("labelle-web: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn execute(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const context_path = try init.minimal.environ.getAlloc(a, "LABELLE_CONTEXT");
    const bytes = try cwd.readFileAlloc(io, context_path, a, .limited(1024 * 1024));
    const parsed = try contract.parseContext(a, bytes, true);
    const ctx = parsed.value;
    const project = ctx.project_dir.?;
    var settings: Settings = .{};
    if (ctx.config_file) |path| {
        const raw = try cwd.readFileAlloc(io, path, a, .limited(1024 * 1024));
        settings = (try std.json.parseFromSlice(Settings, a, raw, .{})).value;
    }
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer args.deinit();
    _ = args.skip();
    var opts: Options = .{};
    while (args.next()) |arg| {
        if (ctx.invocation.kind != .command) return error.UnexpectedHookArguments;
        if (std.mem.startsWith(u8, arg, "--input=")) opts.input = arg[8..] else if (std.mem.startsWith(u8, arg, "--output=")) opts.output = arg[9..] else if (std.mem.startsWith(u8, arg, "--port=")) opts.port = try std.fmt.parseInt(u16, arg[7..], 10) else if (std.mem.eql(u8, arg, "--no-open")) opts.no_open = true else if (std.mem.eql(u8, arg, "--zip")) opts.zip = true else if (std.mem.startsWith(u8, arg, "--platform=")) opts.platform = exporter.parsePlatform(arg[11..]) orelse return error.InvalidExportPlatform else return error.UnknownArgument;
    }
    if ((opts.port orelse settings.port) == 0) return error.InvalidPort;
    const action = ctx.invocation.id;
    if (ctx.invocation.kind == .hook) {
        if (!std.mem.eql(u8, ctx.target.?, "wasm")) return error.UnsupportedTarget;
        const valid = (std.mem.eql(u8, action, "shell") and ctx.invocation.step == .build and ctx.invocation.phase == .after) or
            (std.mem.eql(u8, action, "serve") and ctx.invocation.step == .run and ctx.invocation.phase == .replace) or
            (std.mem.eql(u8, action, "export") and ctx.invocation.step == .bundle and ctx.invocation.phase == .replace);
        if (!valid) return error.InvalidInvocation;
    } else if (!std.mem.eql(u8, action, "serve") and !std.mem.eql(u8, action, "export")) return error.UnknownCommand;
    const input = if (ctx.invocation.kind == .hook and ctx.invocation.step != .bundle)
        try std.fs.path.join(a, &.{ ctx.output_dir, "web" })
    else if (opts.input orelse settings.build_dir) |path|
        try std.fs.path.resolve(a, &.{ project, path })
    else
        try discover(a, io, project);
    const web = try cwd.realPathFileAlloc(io, input, a);
    // Check directory entries, not case-insensitive lookups: deployed HTML
    // requests these exact spellings even when the build host is Windows/macOS.
    const built = try cwd.openDir(io, web, .{ .iterate = true });
    defer built.close(io);
    var entries = built.iterate();
    var js_found = false;
    var wasm_found = false;
    while (try entries.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "game.js")) js_found = entry.kind == .file;
        if (std.mem.eql(u8, entry.name, "game.wasm")) wasm_found = entry.kind == .file;
    }
    if (!js_found or !wasm_found) return error.InvalidBuildArtifact;
    try exporter.validateBuildTree(io, cwd, web);
    const project_web = try std.fs.path.join(a, &.{ project, "web" });
    if (std.mem.eql(u8, action, "export")) {
        if (opts.port != null or opts.no_open) return error.ServeOptionOnExport;
        const out_arg = if (ctx.invocation.kind == .hook) ctx.output_dir else opts.output orelse "dist";
        const out = try canonical(a, io, try std.fs.path.resolve(a, &.{ project, out_arg }));
        const root = try cwd.realPathFileAlloc(io, project, a);
        if (contains(out, root) or contains(out, web) or contains(web, out)) return error.DestructiveOutputPath;
        // A source custom-page directory must survive even if it bears an export marker.
        const custom = try canonical(a, io, project_web);
        if (contains(out, custom) or contains(custom, out)) return error.DestructiveOutputPath;
        try exporter.packageExport(init.gpa, web, project_web, .{ .output_dir = out, .zip = opts.zip, .platform = opts.platform });
    } else {
        if (opts.output != null or opts.zip or opts.platform != .none) return error.ExportOptionOnServe;
        try assets.stage(init.gpa, io, web, project_web);
        if (std.mem.eql(u8, action, "serve")) {
            const port = opts.port orelse settings.port;
            if (port == 0) return error.InvalidPort;
            // Serve the stamped copy, never the original placeholder-bearing source.
            try server.serveAndOpen(init.gpa, web, null, port, settings.open_browser and !opts.no_open, null);
        }
    }
}

/// Find one built target; multi-backend projects must select --input/build_dir.
fn discover(a: std.mem.Allocator, io: std.Io, project: []const u8) ![]const u8 {
    const base = try std.fs.path.join(a, &.{ project, ".labelle" });
    const dir = try std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var selected: ?[]const u8 = null;
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !std.mem.endsWith(u8, entry.name, "_wasm")) continue;
        const path = try std.fs.path.join(a, &.{ base, entry.name, "zig-out", "web" });
        std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ path, "game.wasm" }), .{}) catch continue;
        if (selected != null) return error.AmbiguousBuildOutput;
        selected = path;
    }
    return selected orelse error.MissingWebBuild;
}

/// Canonicalize a future output through its nearest existing parent.
fn canonical(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch |err| switch (err) {
        error.FileNotFound => try std.fs.path.join(a, &.{ try canonical(a, io, std.fs.path.dirname(path) orelse return err), std.fs.path.basename(path) }),
        else => return err,
    };
}
fn contains(parent: []const u8, child: []const u8) bool {
    const prefix = if (@import("builtin").os.tag == .windows) std.ascii.startsWithIgnoreCase(child, parent) else std.mem.startsWith(u8, child, parent);
    return prefix and (child.len == parent.len or (child.len > parent.len and (std.fs.path.isSep(parent[parent.len - 1]) or std.fs.path.isSep(child[parent.len]))));
}

test {
    _ = exporter;
    _ = server;
    _ = contract;
}
