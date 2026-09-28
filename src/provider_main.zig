//! CLI provider entry point (provider contract 1.3.0). One tool serves every
//! command and hook of `plugin.labelle`:
//!
//! - hooks: `toolchain` (before generate) and `toolchain-package` (after
//!   generate) hand the emsdk to the build through `env_file`; `shell`
//!   (after build) stages the loading shell; `serve` (replace run, watch
//!   capable) serves it; `export` (replace bundle) packages it;
//! - commands: `serve`, `export`, `doctor [--json]`,
//!   `toolchain which|install [<version>]`.
//!
//! Diagnostics go to stderr; stdout carries only a command's answer, and
//! nothing under `--progress=json` except `doctor --json`'s document.
const std = @import("std");
const contract = @import("provider/contract.zig");
const config = @import("provider/config.zig");
const assets = @import("provider/assets.zig");
const exporter = @import("provider/export.zig");
const server = @import("provider/serve.zig");
const settings_mod = @import("provider/settings.zig");
const emsdk = @import("provider/emsdk.zig");
const doctor = @import("provider/doctor.zig");
const stdio = @import("provider/stdio.zig");
const watch = @import("provider/watch.zig");
const Settings = settings_mod.Settings;

const Options = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    port: ?u16 = null,
    no_open: bool = false,
    zip: bool = false,
    platform: ?exporter.Platform = null,
    /// The `run.env` of a `run` hook, for the served page.
    run_env: []const server.RunEnv = &.{},
    /// `run.timeout_ms` (`labelle run --timeout`): stop serving then, exit 0.
    timeout_ms: ?u64 = null,
};

pub fn main(init: std.process.Init) !u8 {
    config.io = init.io;
    emsdk.environ = init.minimal.environ;
    execute(init) catch |err| switch (err) {
        // Already explained on stderr.
        error.RequirementsMissing => return 1,
        else => {
            std.debug.print("labelle-web: {s}\n", .{@errorName(err)});
            return 1;
        },
    };
    return 0;
}

const Env = struct {
    emsdk: ?[]const u8,
    offline: bool,
};

fn getEnv(a: std.mem.Allocator, init: std.process.Init, name: []const u8) !?[]const u8 {
    return init.minimal.environ.getAlloc(a, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => err,
    };
}

fn execute(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const context_path = try init.minimal.environ.getAlloc(a, contract.context_env);
    const bytes = try cwd.readFileAlloc(io, context_path, a, .limited(1024 * 1024));
    const parsed = try contract.parseContext(a, bytes, true);
    const ctx = parsed.value;
    // The manifest admits exactly 1.3.x: `cache_dir`, `env_file`, `run.watch`.
    if (!wireAccepted(ctx.contract_version)) return error.UnsupportedContract;
    const project = ctx.project_dir.?;
    const settings = if (ctx.config_file) |path|
        try settings_mod.parse(a, try cwd.readFileAlloc(io, path, a, .limited(1024 * 1024)))
    else
        settings_mod.defaults;
    const env: Env = .{
        .emsdk = try getEnv(a, init, "EMSDK"),
        .offline = emsdk.offlineValue(try getEnv(a, init, "LABELLE_OFFLINE")),
    };
    const inputs: emsdk.Inputs = .{
        .emsdk = settings.emsdk,
        .project_dir = project,
        .cache_dir = ctx.cache_dir.?,
        .inherited = env.emsdk,
        .offline = env.offline,
    };

    var argv: std.ArrayList([]const u8) = .empty;
    {
        var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
        defer args.deinit();
        _ = args.skip();
        while (args.next()) |arg| try argv.append(a, try a.dupe(u8, arg));
    }
    const id = ctx.invocation.id;

    if (ctx.invocation.kind == .hook) {
        if (argv.items.len != 0) return error.UnexpectedHookArguments;
        if (!std.mem.eql(u8, ctx.target.?, "wasm")) return error.UnsupportedTarget;
        const step = ctx.invocation.step.?;
        const phase = ctx.invocation.phase.?;
        if (is(id, "toolchain") and step == .generate and phase == .before) return hookToolchain(a, io, ctx, inputs);
        if (is(id, "toolchain-package") and step == .generate and phase == .after) return hookToolchainPackage(a, io, ctx, inputs);
        if (is(id, "shell") and step == .build and phase == .after) return webAction(init, ctx, settings, .{}, .stage);
        if (is(id, "serve") and step == .run and phase == .replace) {
            const run = ctx.run orelse return error.MissingRunContext;
            var opts = try parseOptions(run.args, .serve);
            const page_env = try a.alloc(server.RunEnv, run.env.len);
            for (run.env, page_env) |from, *to| to.* = .{ .name = from.name, .value = from.value };
            opts.run_env = page_env;
            opts.timeout_ms = run.timeout_ms;
            if (run.watch) |session| return serveSession(init, settings, opts, .{ .generation_file = session.generation_file, .output_dir = session.output_dir });
            return webAction(init, ctx, settings, opts, .serve);
        }
        if (is(id, "export") and step == .bundle and phase == .replace) return webAction(init, ctx, settings, .{}, .@"export");
        return error.InvalidInvocation;
    }

    if (is(id, "serve")) return webAction(init, ctx, settings, try parseOptions(argv.items, .serve), .serve);
    if (is(id, "export")) return webAction(init, ctx, settings, try parseOptions(argv.items, .@"export"), .@"export");
    if (is(id, "doctor")) {
        var json = false;
        for (argv.items) |arg| {
            if (is(arg, "--json")) json = true else {
                std.debug.print("labelle-web: doctor: unknown option '{s}' (usage: labelle web doctor [--json])\n", .{arg});
                return error.UnknownArgument;
            }
        }
        if (!try doctor.run(a, io, emsdk.system, inputs, json)) return error.RequirementsMissing;
        return;
    }
    if (is(id, "toolchain")) return commandToolchain(a, io, ctx, inputs, argv.items);
    return error.UnknownCommand;
}

/// The wires `command_contract = ">=1.3.0 <1.4.0"` admits: 1.3.x, stable.
fn wireAccepted(wire_version: []const u8) bool {
    const wire = std.SemanticVersion.parse(wire_version) catch return false;
    return wire.major == 1 and wire.minor == 3 and wire.pre == null and wire.build == null;
}

fn is(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

// ── Toolchain hooks and command ─────────────────────────────────────────

/// The verified Python 3 command, or a failure naming the fix.
fn requirePython(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    switch (emsdk.checkPython(a, io, emsdk.system)) {
        .found => |cmd| return cmd,
        .python2 => |cmd| {
            std.debug.print(emsdk.python2_found, .{cmd});
            return error.PythonTooOld;
        },
        .missing => {
            std.debug.print("{s}", .{emsdk.python_missing});
            return error.PythonMissing;
        },
    }
}

/// `before generate`: resolve (and, managed, provision) the emsdk and
/// contribute it, so the fingerprint pass and the compile both see it.
fn hookToolchain(a: std.mem.Allocator, io: std.Io, ctx: contract.Context, inputs: emsdk.Inputs) !void {
    var in = inputs;
    in.python = try requirePython(a, io);
    const resolved = (try emsdk.ensure(a, io, emsdk.system, in)) orelse {
        std.debug.print("labelle-web: emsdk.source is \"package\": the fetched emsdk is activated after generation\n", .{});
        return;
    };
    const r = resolved.ready;
    std.debug.print("labelle-web: emsdk from {s}: {s}\n", .{ r.source.label(), r.root });
    try emsdk.writeEnvFile(a, io, ctx.env_file.?, r.root, in.python);
}

/// `after generate`: package mode only. Activate every fetched
/// `zig-pkg/*/emsdk` in place and contribute one of them (the compile
/// onward; the fingerprint pass already ran).
fn hookToolchainPackage(a: std.mem.Allocator, io: std.Io, ctx: contract.Context, in: emsdk.Inputs) !void {
    if (in.emsdk.source != .package) return;
    const python = try requirePython(a, io);
    const root = try emsdk.activatePackages(a, io, emsdk.system, ctx.target_dir.?, in.cache_dir, in.version(), in.offline, python);
    std.debug.print("labelle-web: emsdk from {s}: {s}\n", .{ emsdk.Source.package.label(), root });
    try emsdk.writeEnvFile(a, io, ctx.env_file.?, root, python);
}

/// `labelle web toolchain which|install [<version>]`.
fn commandToolchain(a: std.mem.Allocator, io: std.Io, ctx: contract.Context, in: emsdk.Inputs, argv: []const []const u8) !void {
    const json_progress = ctx.progress == .json;
    const usage = "usage: labelle web toolchain which | install [<version>]\n";
    if (argv.len == 0) {
        std.debug.print("{s}", .{usage});
        return error.UnknownArgument;
    }
    if (is(argv[0], "which") and argv.len == 1) {
        switch (try emsdk.plan(a, io, in)) {
            .ready => |r| try stdio.answer(io, json_progress, "EMSDK: {s}\n  source: {s}\n  installed: yes\n", .{ r.root, r.source.label() }),
            .install => |i| try stdio.answer(io, json_progress, "EMSDK: {s}\n  source: {s}\n  version: {s}\n  installed: no (the next wasm build, or `labelle web toolchain install`, installs it)\n", .{ i.dir, emsdk.Source.managed.label(), i.version }),
            .package => try stdio.answer(io, json_progress, "EMSDK: <target>/zig-pkg/*\n  source: {s}\n  version: {s}\n", .{ emsdk.Source.package.label(), in.version() }),
        }
        return;
    }
    if (is(argv[0], "install") and argv.len <= 2) {
        const version = if (argv.len == 2) argv[1] else in.version();
        if (!settings_mod.safeVersion(version)) return error.InvalidEmsdkVersion;
        const python = try requirePython(a, io);
        const dir = try emsdk.ensureManaged(a, io, emsdk.system, in.cache_dir, version, in.offline, python);
        try stdio.answer(io, json_progress, "emsdk {s}: {s}\n", .{ version, dir });
        return;
    }
    std.debug.print("{s}", .{usage});
    return error.UnknownArgument;
}

// ── Stage, serve and export ─────────────────────────────────────────────

const Action = enum { stage, serve, @"export" };

fn parseOptions(args: []const []const u8, action: Action) !Options {
    var opts: Options = .{};
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--input=")) {
            opts.input = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            opts.output = arg[9..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            opts.port = std.fmt.parseInt(u16, arg[7..], 10) catch return error.InvalidPort;
            if (opts.port.? == 0) return error.InvalidPort;
        } else if (is(arg, "--no-open")) {
            opts.no_open = true;
        } else if (is(arg, "--zip")) {
            opts.zip = true;
        } else if (std.mem.startsWith(u8, arg, "--platform=")) {
            opts.platform = exporter.parsePlatform(arg[11..]) orelse return error.InvalidExportPlatform;
        } else {
            std.debug.print("labelle-web: unknown argument '{s}'\n", .{arg});
            return error.UnknownArgument;
        }
    }
    switch (action) {
        .serve => if (opts.output != null or opts.zip or opts.platform != null) return error.ExportOptionOnServe,
        .@"export" => if (opts.port != null or opts.no_open) return error.ServeOptionOnExport,
        .stage => {},
    }
    return opts;
}

/// A `labelle run --watch` session: serve only the CLI's published output,
/// reload browsers on each new generation. Never writes: the after-build
/// `shell` hook already staged the shell into what was published.
fn serveSession(init: std.process.Init, settings: Settings, opts: Options, session: watch.Session) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const web = try watch.servedRoot(a, io, session);
    try checkRuntime(io, web);
    try exporter.validateBuildTree(io, std.Io.Dir.cwd(), web);
    const port = opts.port orelse settings.port;
    try server.serveAndOpen(init.gpa, web, null, port, settings.open_browser and !opts.no_open, session, opts.run_env, opts.timeout_ms);
}

fn checkRuntime(io: std.Io, web: []const u8) !void {
    // Check directory entries, not case-insensitive lookups: deployed HTML
    // requests these exact spellings even when the build host is Windows/macOS.
    const built = try std.Io.Dir.cwd().openDir(io, web, .{ .iterate = true });
    defer built.close(io);
    var entries = built.iterate();
    var js_found = false;
    var wasm_found = false;
    while (try entries.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "game.js")) js_found = entry.kind == .file;
        if (std.mem.eql(u8, entry.name, "game.wasm")) wasm_found = entry.kind == .file;
    }
    if (!js_found or !wasm_found) return error.InvalidBuildArtifact;
}

fn webAction(init: std.process.Init, ctx: contract.Context, settings: Settings, opts: Options, action: Action) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const project = ctx.project_dir.?;
    const hook = ctx.invocation.kind == .hook;
    const input = if (hook and action != .@"export")
        try std.fs.path.join(a, &.{ ctx.output_dir, "web" })
    else if (hook)
        try std.fs.path.join(a, &.{ ctx.target_dir.?, "zig-out", "web" })
    else if (opts.input orelse settings.build_dir) |path|
        try std.fs.path.resolve(a, &.{ project, path })
    else
        try discover(a, io, project);
    const web = try cwd.realPathFileAlloc(io, input, a);
    try checkRuntime(io, web);
    try exporter.validateBuildTree(io, cwd, web);
    const project_web = try std.fs.path.join(a, &.{ project, "web" });
    switch (action) {
        .@"export" => {
            const out_arg = if (hook) ctx.output_dir else opts.output orelse "dist";
            const out = try canonical(a, io, try std.fs.path.resolve(a, &.{ project, out_arg }));
            const root = try cwd.realPathFileAlloc(io, project, a);
            if (try contains(io, out, root) or try contains(io, out, web) or try contains(io, web, out)) return error.DestructiveOutputPath;
            // A source custom-page directory must survive even if it bears an export marker.
            const custom = try canonical(a, io, project_web);
            if (try contains(io, out, custom) or try contains(io, custom, out)) return error.DestructiveOutputPath;
            try exporter.packageExport(init.gpa, web, project_web, .{
                .output_dir = out,
                .zip = opts.zip or settings.@"export".zip,
                .platform = opts.platform orelse try settings.exportPlatform(),
            });
        },
        .stage, .serve => {
            try assets.stage(init.gpa, io, web, project_web);
            if (action == .serve) {
                const port = opts.port orelse settings.port;
                // Serve the stamped copy, never the original placeholder-bearing source.
                try server.serveAndOpen(init.gpa, web, null, port, settings.open_browser and !opts.no_open, null, opts.run_env, opts.timeout_ms);
            }
        },
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
extern "c" fn fpathconf(fd: c_int, name: c_int) c_long;
fn caseInsensitive(io: std.Io, path: []const u8) !bool {
    const os = @import("builtin").os.tag;
    if (os == .windows) return true;
    if (os != .macos) return false;
    var ancestor = path;
    while (true) {
        const dir = std.Io.Dir.cwd().openDir(io, ancestor, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                ancestor = std.fs.path.dirname(ancestor) orelse return err;
                continue;
            },
            else => return err,
        };
        defer dir.close(io);
        // Darwin sys/unistd.h: _PC_CASE_SENSITIVE = 11. On an unknown
        // filesystem, conservatively protect possible source aliases.
        return fpathconf(dir.handle, 11) != 1;
    }
}
fn contains(io: std.Io, parent: []const u8, child: []const u8) !bool {
    const prefix = if (try caseInsensitive(io, parent)) std.ascii.startsWithIgnoreCase(child, parent) else std.mem.startsWith(u8, child, parent);
    return prefix and (child.len == parent.len or (child.len > parent.len and (std.fs.path.isSep(parent[parent.len - 1]) or std.fs.path.isSep(child[parent.len]))));
}

test "run.args and command options: serve and export options stay apart" {
    const serve_opts = try parseOptions(&.{ "--port=9001", "--no-open" }, .serve);
    try std.testing.expectEqual(@as(?u16, 9001), serve_opts.port);
    try std.testing.expect(serve_opts.no_open);
    try std.testing.expectError(error.InvalidPort, parseOptions(&.{"--port=0"}, .serve));
    try std.testing.expectError(error.InvalidPort, parseOptions(&.{"--port=x"}, .serve));
    try std.testing.expectError(error.UnknownArgument, parseOptions(&.{"--open"}, .serve));
    try std.testing.expectError(error.ExportOptionOnServe, parseOptions(&.{"--zip"}, .serve));
    try std.testing.expectError(error.ServeOptionOnExport, parseOptions(&.{"--no-open"}, .@"export"));
    const export_opts = try parseOptions(&.{ "--output=out", "--platform=itch" }, .@"export");
    try std.testing.expectEqual(exporter.Platform.itch, export_opts.platform.?);
}

test "the tool accepts every 1.3.x wire and nothing else, and still decodes strictly" {
    for ([_][]const u8{ "1.3.0", "1.3.7" }) |wire| try std.testing.expect(wireAccepted(wire));
    for ([_][]const u8{ "1.4.0", "1.2.0", "2.3.0", "1.3.1-rc.1", "x" }) |wire| try std.testing.expect(!wireAccepted(wire));
    const a = std.testing.allocator;
    const ctx = if (@import("builtin").os.tag == .windows)
        \\{"contract_version":"VER","invocation":{"kind":"command","id":"doctor","step":null,"phase":null},"package_dir":"C:\\p","project_dir":"C:\\g","target":"wasm","lock_file":"C:\\g\\labelle.lock","config_file":null,"output_dir":"C:\\o","zig_executable":"C:\\z","optimize":"Debug","progress":"off","target_dir":null,"cache_dir":"C:\\c","env_file":null EXTRA}
    else
        \\{"contract_version":"VER","invocation":{"kind":"command","id":"doctor","step":null,"phase":null},"package_dir":"/p","project_dir":"/g","target":"wasm","lock_file":"/g/labelle.lock","config_file":null,"output_dir":"/o","zig_executable":"/z","optimize":"Debug","progress":"off","target_dir":null,"cache_dir":"/c","env_file":null EXTRA}
    ;
    for ([_][]const u8{ "1.3.0", "1.3.7" }) |wire| {
        const ok = try std.mem.replaceOwned(u8, a, ctx, "VER", wire);
        defer a.free(ok);
        const plain = try std.mem.replaceOwned(u8, a, ok, " EXTRA", "");
        defer a.free(plain);
        const parsed = try contract.parseContext(a, plain, true);
        parsed.deinit();
        // A patch adds no keys: an unknown field is still refused.
        const extra = try std.mem.replaceOwned(u8, a, ok, " EXTRA", ",\"new_key\":1");
        defer a.free(extra);
        try std.testing.expectError(error.UnknownField, contract.parseContext(a, extra, true));
    }
    const newer = try std.mem.replaceOwned(u8, a, ctx, "VER", "1.4.0");
    defer a.free(newer);
    const newer_plain = try std.mem.replaceOwned(u8, a, newer, " EXTRA", "");
    defer a.free(newer_plain);
    try std.testing.expectError(error.UnsupportedContract, contract.parseContext(a, newer_plain, true));
}

test {
    _ = exporter;
    _ = server;
    _ = contract;
    _ = settings_mod;
    _ = emsdk;
    _ = doctor;
    _ = stdio;
    _ = watch;
}
