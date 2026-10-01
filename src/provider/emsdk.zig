//! The emscripten toolchain for `wasm` builds: resolve, provision, activate,
//! and hand to the CLI as an environment contribution (contract 1.3.0
//! `env_file`, RFC labelle-cli#466 §3.2). Ported from labelle-cli
//! `emsdk_toolchain.zig`, `emsdk_cache.zig` and `emsdk_activate.zig`
//! (v2.1.0), which leave the CLI core with RFC #466 PR B.
//!
//! Resolution (`plan`), by settings `emsdk.source`:
//!
//! - `managed` (default): an inherited `EMSDK` whose emcc exists is passed
//!   through; else `emsdk.root`; else the provider-managed install under
//!   `cache_dir` (`managedDir`), installed on first use.
//! - `inherited`: only the inherited `EMSDK`; `root`: only `emsdk.root`.
//!   Either fails instead of falling back.
//! - `package`: nothing before generation; after it, every emsdk Zig fetched
//!   into `<target_dir>/zig-pkg/` is activated in place (`activatePackages`),
//!   so a dependency graph holding two emsdk hashes builds with either.
//!
//! The `toolchain` hook (before generate) writes `env_file` with `EMSDK`,
//! `EM_CONFIG` and a `path_prepend` of `upstream/emscripten` then
//! `upstream/bin` (binaryen's `wasm-opt`, for the bundle export), so the
//! generation-time fingerprint pass, the compile and every later hook see
//! the same toolchain; `toolchain-package` (after generate) does the same
//! for package mode, from the compile onward.
//!
//! Managed layout (versioned; one cache may serve several hosts and SDKs):
//!
//!   <cache_dir>/emsdk/v1/<arch>-<os>/<version>-<commit12>/     the emsdk checkout
//!   <cache_dir>/emsdk/v1/<arch>-<os>/<version>-<commit12>.lock  install lock
//!   <cache_dir>/emsdk/v1/<arch>-<os>/<version>-<commit12>.tmp-* staging (renamed into place)
//!   <install>/.labelle-web-install                             completion marker
//!
//! A directory without the marker is absent: installs are serialized by an
//! exclusive file lock, built in a staging sibling and renamed into place,
//! so two builds racing on one version end with one valid install.
//!
//! This file holds the shared constants, the process runner and the path
//! and state checks, and re-exports the public API of `emsdk/`:
//! `resolve.zig` (source resolution), `managed.zig` (managed install),
//! `package.zig` (package mode), `env.zig` (environment contribution and
//! `wasm-opt` lookup) and `python.zig` (interpreter check).
const std = @import("std");
const builtin = @import("builtin");
const stdio = @import("stdio.zig");

pub const is_windows = builtin.os.tag == .windows;

/// The emsdk the backends' `emsdk` Zig dependency pins, and the CLI's
/// pinned default through v2.x.
pub const default_version = "4.0.9";
/// The `4.0.9` tag's commit, verified after the shallow clone.
pub const default_commit = "3bcf1dcd01f040f370e10fe673a092d9ed79ebb5";
pub const git_url = "https://github.com/emscripten-core/emsdk.git";

/// Versions whose tag commit is pinned. Another version is fetched by tag
/// over HTTPS and keyed `<version>-tag`.
const pinned = [_]struct { version: []const u8, commit: []const u8 }{
    .{ .version = default_version, .commit = default_commit },
};

pub fn pinnedCommit(version: []const u8) ?[]const u8 {
    for (pinned) |p| if (std.mem.eql(u8, p.version, version)) return p.commit;
    return null;
}

pub const layout = "v1";
pub const host_key = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
pub const launcher_name = if (is_windows) "emsdk.bat" else "emsdk";
pub const emcc_name = if (is_windows) "emcc.bat" else "emcc";
pub const em_config_name = ".emscripten";
pub const marker_name = ".labelle-web-install";
/// In an in-place (package mode) activation: the version activated there.
pub const package_marker_name = ".labelle-web-activated";
pub const sep = std.fs.path.sep_str;
pub const emscripten_rel = "upstream" ++ sep ++ "emscripten";
pub const emcc_rel = emscripten_rel ++ sep ++ emcc_name;
/// The LLVM + binaryen binaries: `wasm-opt` for the export's optimize pass.
pub const upstream_bin_rel = "upstream" ++ sep ++ "bin";
pub const wasm_opt_name = if (is_windows) "wasm-opt.exe" else "wasm-opt";

// ── Process execution (injectable for host tests) ───────────────────────

/// How the module runs git and the emsdk launcher. `system` spawns real
/// processes; tests substitute a fake.
pub const Runner = struct {
    ctx: ?*anyopaque = null,
    /// Run `argv` in `cwd` with `env` added to the inherited environment,
    /// the child's stdout sent to stderr. Returns the exit status (a signal
    /// is 255).
    step: *const fn (ctx: ?*anyopaque, io: std.Io, a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, env: []const EnvVar) anyerror!u8,
    /// Run `argv` in `cwd` and return its stdout (null on failure).
    capture: *const fn (ctx: ?*anyopaque, io: std.Io, a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!?[]u8,
};

pub const system: Runner = .{ .step = systemStep, .capture = systemCapture };

/// The provider's inherited environment, for children that need additions
/// (`main` sets it; null keeps the plain inherited environment).
pub var environ: ?std.process.Environ = null;

fn systemStep(_: ?*anyopaque, io: std.Io, a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, env: []const EnvVar) anyerror!u8 {
    var map: ?std.process.Environ.Map = null;
    defer if (map) |*m| m.deinit();
    if (env.len != 0) if (environ) |inherited| {
        map = try inherited.createMap(a);
        for (env) |pair| try map.?.put(pair.name, pair.value);
    };
    const environ_map: ?*const std.process.Environ.Map = if (map) |*m| m else null;
    if (is_windows) {
        // Handing the stderr handle to a Windows child as its stdout failed
        // with NoDevice on windows-latest; capture (as the CLI's own emsdk
        // steps did) and relay both streams to stderr afterwards.
        const result = try std.process.run(a, io, .{ .argv = argv, .cwd = if (cwd) |c| .{ .path = c } else .inherit, .environ_map = environ_map });
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        var buf: [4096]u8 = undefined;
        var w = stdio.stderrWriter(io, &buf);
        w.interface.writeAll(result.stdout) catch {};
        w.interface.writeAll(result.stderr) catch {};
        w.interface.flush() catch {};
        return switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
    }
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = stdio.childStdout(),
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

fn systemCapture(_: ?*anyopaque, io: std.Io, a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!?[]u8 {
    const result = std.process.run(a, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
    }) catch return null;
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    a.free(result.stdout);
    return null;
}

/// The environment the emsdk launcher gets: on Windows `EMSDK_PYTHON`, which
/// `emsdk.bat` (and later `emcc.bat`) honour, names the interpreter this
/// provider verified instead of whatever `python` resolves to. The POSIX
/// launcher runs `python3`, the command verified there.
pub fn launcherEnv(a: std.mem.Allocator, python: ?[]const u8, windows: bool) ![]const EnvVar {
    const cmd = python orelse return &.{};
    if (!windows) return &.{};
    return a.dupe(EnvVar, &.{.{ .name = "EMSDK_PYTHON", .value = cmd }});
}

pub fn launcherArgv(a: std.mem.Allocator, launcher: []const u8, sub: []const u8, version: []const u8) ![]const []const u8 {
    if (is_windows) return a.dupe([]const u8, &.{ "cmd", "/c", launcher, sub, version });
    return a.dupe([]const u8, &.{ launcher, sub, version });
}

// ── Paths and state ─────────────────────────────────────────────────────

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// True when `root` holds an emcc (what the backends look for under `EMSDK`).
pub fn hasEmcc(a: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const emcc = std.fs.path.join(a, &.{ root, emcc_rel }) catch return false;
    defer a.free(emcc);
    return exists(io, emcc);
}

/// A checkout is activated when both `emcc` (`emsdk install`) and the
/// `.emscripten` EM_CONFIG (`emsdk activate`) exist: an interrupted
/// activation can leave emcc without the config.
pub fn activated(a: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const config = std.fs.path.join(a, &.{ root, em_config_name }) catch return false;
    defer a.free(config);
    return hasEmcc(a, io, root) and exists(io, config);
}

/// `<version>-<first 12 hex of the pinned commit>`, or `<version>-tag`.
pub fn sdkKey(a: std.mem.Allocator, version: []const u8) ![]u8 {
    if (pinnedCommit(version)) |commit| return std.fmt.allocPrint(a, "{s}-{s}", .{ version, commit[0..12] });
    return std.fmt.allocPrint(a, "{s}-tag", .{version});
}

/// Where the managed install of `version` lives for this host.
pub fn managedDir(a: std.mem.Allocator, cache_dir: []const u8, version: []const u8) ![]u8 {
    const key = try sdkKey(a, version);
    defer a.free(key);
    return std.fs.path.join(a, &.{ cache_dir, "emsdk", layout, host_key, key });
}

/// A managed install is complete once its marker and an activated tree exist.
pub fn managedComplete(a: std.mem.Allocator, io: std.Io, dir: []const u8) bool {
    const marker = std.fs.path.join(a, &.{ dir, marker_name }) catch return false;
    defer a.free(marker);
    return exists(io, marker) and activated(a, io, dir);
}

/// `LABELLE_OFFLINE` set to anything but empty or `0`, as the CLI reads it.
pub fn offlineValue(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

pub const EnvVar = struct { name: []const u8, value: []const u8 };

// ── Submodules ──────────────────────────────────────────────────────────

const resolve_mod = @import("emsdk/resolve.zig");
const managed_mod = @import("emsdk/managed.zig");
const package_mod = @import("emsdk/package.zig");
const env_mod = @import("emsdk/env.zig");
const python_mod = @import("emsdk/python.zig");

pub const Source = resolve_mod.Source;
pub const Inputs = resolve_mod.Inputs;
pub const Plan = resolve_mod.Plan;
pub const plan = resolve_mod.plan;
pub const ensure = resolve_mod.ensure;
pub const ensureManaged = managed_mod.ensureManaged;
pub const findPackages = package_mod.findPackages;
pub const activatePackages = package_mod.activatePackages;
pub const packagesReady = package_mod.packagesReady;
pub const default_backend = package_mod.default_backend;
pub const projectBackend = package_mod.projectBackend;
pub const selectedTargetDir = package_mod.selectedTargetDir;
pub const Contribution = env_mod.Contribution;
pub const contribution = env_mod.contribution;
pub const writeEnvFile = env_mod.writeEnvFile;
pub const writeVarsOnly = env_mod.writeVarsOnly;
pub const wasmOptPath = env_mod.wasmOptPath;
pub const PythonCheck = python_mod.PythonCheck;
pub const checkPython = python_mod.checkPython;
pub const findPython = python_mod.findPython;
pub const python2_found = python_mod.python2_found;
pub const python_missing = python_mod.python_missing;

// ── Tests ───────────────────────────────────────────────────────────────

// Every submodule is analyzed (and its tests run) wherever this file's tests are.
test {
    _ = resolve_mod;
    _ = managed_mod;
    _ = package_mod;
    _ = env_mod;
    _ = python_mod;
}

const testing = std.testing;

test "managed layout is keyed by layout, host and SDK identity" {
    const a = testing.allocator;
    const dir = try managedDir(a, "/c", "4.0.9");
    defer a.free(dir);
    const want = try std.fs.path.join(a, &.{ "/c", "emsdk", "v1", host_key, "4.0.9-3bcf1dcd01f0" });
    defer a.free(want);
    try testing.expectEqualStrings(want, dir);
    const other = try managedDir(a, "/c", "3.1.50");
    defer a.free(other);
    try testing.expect(std.mem.endsWith(u8, other, "3.1.50-tag"));
}

test "offline follows the CLI's LABELLE_OFFLINE reading" {
    try testing.expect(!offlineValue(null));
    try testing.expect(!offlineValue(""));
    try testing.expect(!offlineValue("0"));
    try testing.expect(offlineValue("1"));
    try testing.expect(offlineValue("yes"));
}
