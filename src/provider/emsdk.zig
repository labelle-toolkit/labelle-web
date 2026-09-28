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
//! `EM_CONFIG` and a `path_prepend` of `upstream/emscripten`, so the
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
const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");
const stdio = @import("stdio.zig");

const is_windows = builtin.os.tag == .windows;

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
const sep = std.fs.path.sep_str;
pub const emscripten_rel = "upstream" ++ sep ++ "emscripten";
pub const emcc_rel = emscripten_rel ++ sep ++ emcc_name;

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

fn launcherArgv(a: std.mem.Allocator, launcher: []const u8, sub: []const u8, version: []const u8) ![]const []const u8 {
    if (is_windows) return a.dupe([]const u8, &.{ "cmd", "/c", launcher, sub, version });
    return a.dupe([]const u8, &.{ launcher, sub, version });
}

// ── Paths and state ─────────────────────────────────────────────────────

fn exists(io: std.Io, path: []const u8) bool {
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
fn activated(a: std.mem.Allocator, io: std.Io, root: []const u8) bool {
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

// ── Resolution ──────────────────────────────────────────────────────────

pub const Source = enum {
    inherited,
    root,
    managed,
    package,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .inherited => "inherited EMSDK",
            .root => "settings emsdk.root",
            .managed => "managed install (cache_dir)",
            .package => "package: zig-pkg emsdk activated in place",
        };
    }
};

pub const Inputs = struct {
    emsdk: settings_mod.Emsdk,
    project_dir: []const u8,
    cache_dir: []const u8,
    /// `EMSDK` from the environment the provider inherited.
    inherited: ?[]const u8,
    offline: bool,
    /// The verified Python 3 command (`findPython`), for the launcher.
    python: ?[]const u8 = null,
    /// The resolved target (`wasm`), naming the generated tree.
    target: []const u8 = "wasm",

    pub fn version(self: Inputs) []const u8 {
        return self.emsdk.version orelse default_version;
    }
};

/// What a build would use, decided without side effects.
pub const Plan = union(enum) {
    /// An existing, usable emsdk root.
    ready: struct { root: []const u8, source: Source },
    /// The managed install, not installed yet.
    install: struct { dir: []const u8, version: []const u8 },
    /// Package mode: activation happens after generation.
    package,
};

pub fn plan(a: std.mem.Allocator, io: std.Io, in: Inputs) !Plan {
    switch (in.emsdk.source) {
        .package => return .package,
        .inherited => {
            const root = in.inherited orelse {
                std.debug.print("labelle-web: emsdk.source is \"inherited\" but EMSDK is not set\n", .{});
                return error.InheritedEmsdkMissing;
            };
            const abs = try std.fs.path.resolve(a, &.{ in.project_dir, root });
            if (!activated(a, io, abs)) {
                std.debug.print("labelle-web: EMSDK={s} is not an activated emsdk: it needs {s} and {s} (run `emsdk activate`)\n", .{ abs, emcc_rel, em_config_name });
                return error.InheritedEmsdkMissing;
            }
            return .{ .ready = .{ .root = abs, .source = .inherited } };
        },
        .root, .managed => {},
    }
    if (in.emsdk.source == .managed) {
        if (in.inherited) |root| if (root.len != 0) {
            const abs = try std.fs.path.resolve(a, &.{ in.project_dir, root });
            if (activated(a, io, abs)) return .{ .ready = .{ .root = abs, .source = .inherited } };
            std.debug.print("labelle-web: ignoring EMSDK={s}: not an activated emsdk ({s} and {s} needed)\n", .{ abs, emcc_rel, em_config_name });
        };
    }
    if (in.emsdk.root) |root| {
        const abs = try std.fs.path.resolve(a, &.{ in.project_dir, root });
        if (!activated(a, io, abs)) {
            std.debug.print("labelle-web: settings emsdk.root {s} is not an activated emsdk: it needs {s} and {s} (run `emsdk activate`)\n", .{ abs, emcc_rel, em_config_name });
            return error.EmsdkRootInvalid;
        }
        return .{ .ready = .{ .root = abs, .source = .root } };
    }
    std.debug.assert(in.emsdk.source == .managed);
    const dir = try managedDir(a, in.cache_dir, in.version());
    if (managedComplete(a, io, dir)) return .{ .ready = .{ .root = dir, .source = .managed } };
    return .{ .install = .{ .dir = dir, .version = in.version() } };
}

/// Resolve and, for the managed install, provision. Null in package mode.
pub fn ensure(a: std.mem.Allocator, io: std.Io, runner: Runner, in: Inputs) !?Plan {
    const p = try plan(a, io, in);
    return switch (p) {
        .ready => p,
        .package => null,
        .install => |i| .{ .ready = .{ .root = try ensureManaged(a, io, runner, in.cache_dir, i.version, in.offline, in.python), .source = .managed } },
    };
}

// ── Managed install ─────────────────────────────────────────────────────

/// Install `version` under `cache_dir` unless a complete install exists.
/// Returns the install directory.
pub fn ensureManaged(a: std.mem.Allocator, io: std.Io, runner: Runner, cache_dir: []const u8, version: []const u8, offline: bool, python: ?[]const u8) ![]const u8 {
    if (!settings_mod.safeVersion(version)) return error.InvalidEmsdkVersion;
    const cwd = std.Io.Dir.cwd();
    const dir = try managedDir(a, cache_dir, version);
    if (managedComplete(a, io, dir)) return dir;
    if (offline) {
        std.debug.print(
            "labelle-web: emsdk {s} is not installed at {s} and LABELLE_OFFLINE is set; " ++
                "run `labelle web toolchain install {s}` with network access first\n",
            .{ version, dir, version },
        );
        return error.EmsdkNotInstalledOffline;
    }
    const parent = std.fs.path.dirname(dir).?;
    try cwd.createDirPath(io, parent);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{dir});
    const lock = cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        std.debug.print("labelle-web: could not lock {s}: {s}\n", .{ lock_path, @errorName(err) });
        return error.EmsdkInstallLockFailed;
    };
    defer lock.close(io);
    // Another build may have finished the install while this one waited.
    if (managedComplete(a, io, dir)) {
        std.debug.print("labelle-web: emsdk {s} was installed by another build: {s}\n", .{ version, dir });
        return dir;
    }
    // Holding the lock: any staging sibling is an interrupted install's.
    const base = std.fs.path.basename(dir);
    const stale_prefix = try std.fmt.allocPrint(a, "{s}.tmp-", .{base});
    removeStale(a, io, parent, stale_prefix);

    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const staging = try std.fmt.allocPrint(a, "{s}.tmp-{x}", .{ dir, std.mem.readInt(u64, &rnd, .little) });
    defer cwd.deleteTree(io, staging) catch {};

    std.debug.print("labelle-web: installing emsdk {s} into {s}\n", .{ version, dir });
    if (try runner.step(runner.ctx, io, a, &.{ "git", "clone", "--depth", "1", "--branch", version, git_url, staging }, null, &.{}) != 0) {
        std.debug.print("labelle-web: git clone of emsdk {s} failed\n", .{version});
        return error.EmsdkFetchFailed;
    }
    if (pinnedCommit(version)) |commit| {
        const out = (try runner.capture(runner.ctx, io, a, &.{ "git", "rev-parse", "HEAD" }, staging)) orelse {
            std.debug.print("labelle-web: could not read the emsdk checkout's commit\n", .{});
            return error.EmsdkVerificationFailed;
        };
        const head = std.mem.trim(u8, out, " \t\r\n");
        if (!std.mem.eql(u8, head, commit)) {
            std.debug.print("labelle-web: emsdk {s} commit mismatch: expected {s}, got {s}\n", .{ version, commit, head });
            return error.EmsdkVerificationFailed;
        }
        std.debug.print("  commit verified ({s})\n", .{commit});
    } else std.debug.print("  note: emsdk {s} has no pinned commit; trusting the HTTPS tag fetch\n", .{version});

    try activateIn(a, io, runner, staging, version, python);
    const marker = try std.fs.path.join(a, &.{ staging, marker_name });
    const record = try std.fmt.allocPrint(a, "{{\"layout\":\"{s}\",\"version\":\"{s}\",\"commit\":\"{s}\",\"host\":\"{s}\"}}\n", .{ layout, version, pinnedCommit(version) orelse "tag", host_key });
    try cwd.writeFile(io, .{ .sub_path = marker, .data = record });
    // An incomplete tree at the destination (no marker) is absent.
    cwd.deleteTree(io, dir) catch {};
    try cwd.rename(staging, cwd, dir, io);
    std.debug.print("  emsdk {s} ready at {s}\n", .{ version, dir });
    return dir;
}

fn removeStale(a: std.mem.Allocator, io: std.Io, parent: []const u8, prefix: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) names.append(a, a.dupe(u8, entry.name) catch return) catch return;
    }
    for (names.items) |name| dir.deleteTree(io, name) catch {};
}

/// `emsdk install <v>` then `emsdk activate <v>` in `root`, checked.
fn activateIn(a: std.mem.Allocator, io: std.Io, runner: Runner, root: []const u8, version: []const u8, python: ?[]const u8) !void {
    const env = try launcherEnv(a, python, is_windows);
    const launcher = try std.fs.path.join(a, &.{ root, launcher_name });
    if (!is_windows) {
        if (std.Io.Dir.cwd().openFile(io, launcher, .{})) |file| {
            defer file.close(io);
            file.setPermissions(io, .fromMode(0o755)) catch {};
        } else |_| {}
    }
    for ([_][]const u8{ "install", "activate" }) |sub| {
        std.debug.print("  emsdk {s} {s}\n", .{ sub, version });
        if (try runner.step(runner.ctx, io, a, try launcherArgv(a, launcher, sub, version), root, env) != 0) {
            std.debug.print("labelle-web: `emsdk {s} {s}` failed in {s}\n", .{ sub, version, root });
            return error.EmsdkStepFailed;
        }
    }
    if (!activated(a, io, root)) {
        std.debug.print("labelle-web: emsdk {s} activated but {s} or {s} is missing under {s}\n", .{ version, emcc_rel, em_config_name, root });
        return error.EmsdkActivationIncomplete;
    }
}

// ── Package mode ────────────────────────────────────────────────────────

/// Every emsdk checkout Zig fetched into `<target_dir>/zig-pkg/`: a
/// directory holding both the launcher and `emsdk.py`. Sorted.
pub fn findPackages(a: std.mem.Allocator, io: std.Io, target_dir: []const u8) ![]const []const u8 {
    const root = try std.fs.path.join(a, &.{ target_dir, "zig-pkg" });
    var list: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return list.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const cand = try std.fs.path.join(a, &.{ root, entry.name });
        const launcher = try std.fs.path.join(a, &.{ cand, launcher_name });
        const py = try std.fs.path.join(a, &.{ cand, "emsdk.py" });
        if (exists(io, launcher) and exists(io, py)) try list.append(a, cand);
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return list.items;
}

/// Activate every fetched emsdk in place (each under its own lock) and
/// return the one the target's `build.zig.zon` names, else the first.
pub fn activatePackages(a: std.mem.Allocator, io: std.Io, runner: Runner, target_dir: []const u8, cache_dir: []const u8, version: []const u8, offline: bool, python: ?[]const u8) ![]const u8 {
    if (!settings_mod.safeVersion(version)) return error.InvalidEmsdkVersion;
    const pkgs = try findPackages(a, io, target_dir);
    if (pkgs.len == 0) {
        std.debug.print("labelle-web: emsdk.source is \"package\" but no emsdk was fetched under {s}" ++ sep ++ "zig-pkg\n", .{target_dir});
        return error.NoFetchedEmsdk;
    }
    const cwd = std.Io.Dir.cwd();
    const locks = try std.fs.path.join(a, &.{ cache_dir, "emsdk", layout, "package-locks" });
    try cwd.createDirPath(io, locks);
    for (pkgs) |pkg| {
        if (try packageCurrent(a, io, pkg, version)) continue;
        if (offline) {
            std.debug.print("labelle-web: the fetched emsdk {s} is not activated for {s} and LABELLE_OFFLINE is set\n", .{ pkg, version });
            return error.EmsdkNotInstalledOffline;
        }
        const lock_path = try std.fmt.allocPrint(a, "{s}" ++ sep ++ "{x}.lock", .{ locks, std.hash.Wyhash.hash(0, pkg) });
        const lock = cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
            std.debug.print("labelle-web: could not lock {s}: {s}\n", .{ lock_path, @errorName(err) });
            return error.EmsdkInstallLockFailed;
        };
        defer lock.close(io);
        if (try packageCurrent(a, io, pkg, version)) continue;
        std.debug.print("labelle-web: activating fetched emsdk {s} in place: {s}\n", .{ version, pkg });
        makeTreeWritable(io, pkg);
        try activateIn(a, io, runner, pkg, version, python);
        const marker = try std.fs.path.join(a, &.{ pkg, package_marker_name });
        try cwd.writeFile(io, .{ .sub_path = marker, .data = version });
    }
    if (try zonEmsdkHash(a, io, target_dir)) |hash| {
        for (pkgs) |pkg| if (std.mem.eql(u8, std.fs.path.basename(pkg), hash)) return pkg;
    }
    return pkgs[0];
}

/// Package mode keeps its own record of what it activated in a fetched tree.
/// A tree activated for another `emsdk.version` (settings changed), or by
/// someone else (the tree carries no record, e.g. the CLI 2.x core's own
/// activation), is re-activated for the requested version: `emsdk install`
/// adds it beside the old one and `emsdk activate` switches `.emscripten`.
fn packageCurrent(a: std.mem.Allocator, io: std.Io, pkg: []const u8, version: []const u8) !bool {
    if (!activated(a, io, pkg)) return false;
    const marker = try std.fs.path.join(a, &.{ pkg, package_marker_name });
    const recorded = std.Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(256)) catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, recorded, " \r\n"), version);
}

/// Package mode without network: can every fetched emsdk in the selected
/// target's `zig-pkg/` already serve `version`? False when there is none
/// (not generated or nothing fetched yet) or one still needs `emsdk
/// install`. Only `target_dir` counts: a tree left over from another
/// backend says nothing about the next build.
pub fn packagesReady(a: std.mem.Allocator, io: std.Io, target_dir: []const u8, version: []const u8) !bool {
    const pkgs = try findPackages(a, io, target_dir);
    if (pkgs.len == 0) return false;
    for (pkgs) |pkg| if (!try packageCurrent(a, io, pkg, version)) return false;
    return true;
}

/// The CLI's default backend when `project.labelle` declares none.
pub const default_backend = "bgfx";

/// The backend `project.labelle` selects (`.backend = .<name>`), else
/// `default_backend`. A line scan: `//` comments are ignored.
pub fn projectBackend(a: std.mem.Allocator, io: std.Io, project_dir: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ project_dir, "project.labelle" });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return default_backend;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOf(u8, raw, "//") orelse raw.len];
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, line, at, ".backend")) |i| {
            at = i + ".backend".len;
            var j = at;
            while (j < line.len and line[j] == ' ') j += 1;
            if (j >= line.len or line[j] != '=') continue;
            j += 1;
            while (j < line.len and line[j] == ' ') j += 1;
            if (j >= line.len or line[j] != '.') continue;
            j += 1;
            const start = j;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_')) j += 1;
            if (j > start) return line[start..j];
        }
    }
    return default_backend;
}

/// `<project>/.labelle/<backend>_<target>`: the generated tree a build of
/// `target` uses, as the CLI names it.
pub fn selectedTargetDir(a: std.mem.Allocator, io: std.Io, project_dir: []const u8, target: []const u8) ![]const u8 {
    const backend = try projectBackend(a, io, project_dir);
    return std.fs.path.join(a, &.{ project_dir, ".labelle", try std.fmt.allocPrint(a, "{s}_{s}", .{ backend, target }) });
}

test "projectBackend reads .backend, ignoring comments, else the default" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const project = try t.path(&.{"p"});
    try std.Io.Dir.cwd().createDirPath(testing.io, project);
    try testing.expectEqualStrings(default_backend, try projectBackend(a, testing.io, project));
    const file = try t.path(&.{ "p", "project.labelle" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file, .data = ".{\n    // .backend = .raylib,\n    .backend = .sokol,\n}\n" });
    try testing.expectEqualStrings("sokol", try projectBackend(a, testing.io, project));
    const dir = try selectedTargetDir(a, testing.io, project, "wasm");
    try testing.expectEqualStrings(try t.path(&.{ "p", ".labelle", "sokol_wasm" }), dir);
}

/// The `emsdk` dependency hash in the target's `build.zig.zon`, if any.
fn zonEmsdkHash(a: std.mem.Allocator, io: std.Io, target_dir: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(a, &.{ target_dir, "build.zig.zon" });
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return null;
    const Shape = struct { dependencies: ?struct { emsdk: ?struct { hash: []const u8 = "" } = null } = null };
    @setEvalBranchQuota(10000);
    const parsed = std.zon.parse.fromSliceAlloc(Shape, a, try a.dupeZ(u8, raw), null, .{ .ignore_unknown_fields = true }) catch return null;
    const hash = (parsed.dependencies orelse return null).emsdk orelse return null;
    if (hash.hash.len == 0) return null;
    for (hash.hash) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.' => {},
        else => return null,
    };
    return hash.hash;
}

/// Zig marks fetched package directories read-only; `emsdk install` must
/// create `upstream/`, `node/` and `.emscripten` there. Best-effort, POSIX.
fn makeTreeWritable(io: std.Io, root: []const u8) void {
    if (is_windows) return;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    dir.setPermissions(io, .fromMode(0o755)) catch {};
    var walker = dir.walk(std.heap.page_allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        entry.dir.setFilePermissions(io, entry.basename, .fromMode(0o755), .{}) catch {};
    }
}

// ── Environment contribution ────────────────────────────────────────────

pub const EnvVar = struct { name: []const u8, value: []const u8 };
pub const Contribution = struct {
    set: []const EnvVar,
    path_prepend: []const []const u8,
};

/// `EMSDK`, `EM_CONFIG` (when the root has one) and `upstream/emscripten`
/// in front of PATH.
pub fn contribution(a: std.mem.Allocator, io: std.Io, root: []const u8, python: ?[]const u8) !Contribution {
    var set: std.ArrayList(EnvVar) = .empty;
    try set.append(a, .{ .name = "EMSDK", .value = root });
    const config = try std.fs.path.join(a, &.{ root, em_config_name });
    if (exists(io, config)) try set.append(a, .{ .name = "EM_CONFIG", .value = config });
    // emcc.bat runs `%EMSDK_PYTHON%` when set: the same interpreter as the launcher.
    try set.appendSlice(a, try launcherEnv(a, python, is_windows));
    const bin = try std.fs.path.join(a, &.{ root, emscripten_rel });
    return .{ .set = set.items, .path_prepend = try a.dupe([]const u8, &.{bin}) };
}

pub fn writeEnvFile(a: std.mem.Allocator, io: std.Io, path: []const u8, root: []const u8, python: ?[]const u8) !void {
    const value = try contribution(a, io, root, python);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

// ── Python ──────────────────────────────────────────────────────────────

/// The outcome of looking for the interpreter emsdk and emcc will run.
pub const PythonCheck = union(enum) {
    /// A command that runs Python 3.
    found: []const u8,
    /// The first command that ran was Python 2 (and no Python 3 was found).
    python2: []const u8,
    missing,
};

/// Look for Python 3: `python3` on POSIX (the launcher's and emcc's
/// interpreter), `python` then `python3` on Windows. Each candidate runs
/// `import sys; print(sys.version_info[0])`, which answers on Python 2 and 3
/// alike and fails on the Windows Store stub; only `3` is accepted.
pub fn checkPython(a: std.mem.Allocator, io: std.Io, runner: Runner) PythonCheck {
    const candidates: []const []const u8 = if (is_windows) &.{ "python", "python3" } else &.{"python3"};
    var old: ?[]const u8 = null;
    for (candidates) |cmd| {
        const out = (runner.capture(runner.ctx, io, a, &.{ cmd, "-c", "import sys; print(sys.version_info[0])" }, null) catch null) orelse continue;
        defer a.free(out);
        const major = std.mem.trim(u8, out, " \t\r\n");
        if (std.mem.eql(u8, major, "3")) return .{ .found = cmd };
        if (old == null) old = cmd;
    }
    return if (old) |cmd| .{ .python2 = cmd } else .missing;
}

pub fn findPython(a: std.mem.Allocator, io: std.Io, runner: Runner) ?[]const u8 {
    return switch (checkPython(a, io, runner)) {
        .found => |cmd| cmd,
        else => null,
    };
}

pub const python2_found =
    "labelle-web: `{s}` is Python 2, and emsdk and emcc need Python 3.\n" ++
    "  fix: run `labelle install python` (the CLI puts its managed Python on PATH),\n" ++
    "  or install Python 3 and put it first on PATH.\n";

pub const python_missing =
    "labelle-web: emsdk and emcc need Python 3, and none was found on PATH.\n" ++
    "  fix: run `labelle install python` (the CLI puts its managed Python on PATH),\n" ++
    "  or install Python 3 yourself and put `python3` on PATH.\n";

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// A fake git/emsdk: `clone` lays out a checkout (launcher + emsdk.py),
/// `rev-parse` answers `commit`, `install` creates emcc, `activate` the
/// config. Records how many clones and activations ran.
const Fake = struct {
    commit: []const u8 = default_commit,
    clones: usize = 0,
    installs: usize = 0,
    fail_activate: bool = false,
    has_python: bool = true,
    /// What `-c "print(sys.version_info[0])"` answers per command.
    python_major: []const u8 = "3",
    /// `EMSDK_PYTHON` as the last launcher step received it.
    launcher_python: ?[]const u8 = null,

    fn runner(self: *Fake) Runner {
        return .{ .ctx = self, .step = step, .capture = capture };
    }

    fn touch(io: std.Io, a: std.mem.Allocator, parts: []const []const u8) !void {
        const path = try std.fs.path.join(a, parts);
        defer a.free(path);
        if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "fake" });
    }

    fn step(ctx: ?*anyopaque, io: std.Io, a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, env: []const EnvVar) anyerror!u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.launcher_python = null;
        for (env) |pair| if (std.mem.eql(u8, pair.name, "EMSDK_PYTHON")) {
            self.launcher_python = pair.value;
        };
        const sub_at: usize = if (is_windows and std.mem.eql(u8, argv[0], "cmd")) 3 else 1;
        if (std.mem.eql(u8, argv[0], "git") and std.mem.eql(u8, argv[1], "clone")) {
            self.clones += 1;
            const dest = argv[argv.len - 1];
            try touch(io, a, &.{ dest, launcher_name });
            try touch(io, a, &.{ dest, "emsdk.py" });
            return 0;
        }
        const root = cwd.?;
        if (std.mem.eql(u8, argv[sub_at], "install")) {
            self.installs += 1;
            try touch(io, a, &.{ root, emcc_rel });
            return 0;
        }
        if (std.mem.eql(u8, argv[sub_at], "activate")) {
            if (self.fail_activate) return 1;
            try touch(io, a, &.{ root, em_config_name });
            return 0;
        }
        return 2;
    }

    fn capture(ctx: ?*anyopaque, _: std.Io, a: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!?[]u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, argv[0], "git")) return try a.dupe(u8, self.commit);
        if (std.mem.startsWith(u8, argv[0], "python")) return if (self.has_python) try std.fmt.allocPrint(a, "{s}\n", .{self.python_major}) else null;
        return null;
    }
};

const Tmp = struct {
    dir: testing.TmpDir,
    root: []const u8,
    arena: std.heap.ArenaAllocator,

    fn init() !Tmp {
        var t: Tmp = .{ .dir = testing.tmpDir(.{}), .root = undefined, .arena = .init(testing.allocator) };
        t.root = try t.dir.dir.realPathFileAlloc(testing.io, ".", t.arena.allocator());
        return t;
    }
    fn deinit(t: *Tmp) void {
        t.arena.deinit();
        t.dir.cleanup();
    }
    fn path(t: *Tmp, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(t.arena.allocator(), t.root);
        try all.appendSlice(t.arena.allocator(), parts);
        return std.fs.path.join(t.arena.allocator(), all.items);
    }
};

/// An activated-looking emsdk: emcc and the `.emscripten` config.
fn fakeActivated(a: std.mem.Allocator, root: []const u8) !void {
    try Fake.touch(testing.io, a, &.{ root, emcc_rel });
    try Fake.touch(testing.io, a, &.{ root, em_config_name });
}

fn inputs(t: *Tmp, emsdk: settings_mod.Emsdk, inherited: ?[]const u8) !Inputs {
    return .{ .emsdk = emsdk, .project_dir = try t.path(&.{"project"}), .cache_dir = try t.path(&.{"cache"}), .inherited = inherited, .offline = false };
}

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

test "plan: an inherited EMSDK with emcc is passed through, without an install" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const ext = try t.path(&.{"external-emsdk"});
    try fakeActivated(a, ext);
    var fake: Fake = .{};
    const got = (try ensure(a, testing.io, fake.runner(), try inputs(&t, .{}, ext))).?;
    try testing.expectEqual(Source.inherited, got.ready.source);
    try testing.expectEqualStrings(ext, got.ready.root);
    try testing.expectEqual(@as(usize, 0), fake.clones);
}

test "plan: a stale inherited EMSDK falls through to emsdk.root, then to the managed install" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const stale = try t.path(&.{"stale"});
    const root = try t.path(&.{"root-emsdk"});
    try fakeActivated(a, root);
    const via_root = try plan(a, testing.io, try inputs(&t, .{ .root = root }, stale));
    try testing.expectEqual(Source.root, via_root.ready.source);
    const via_managed = try plan(a, testing.io, try inputs(&t, .{}, stale));
    try testing.expect(via_managed == .install);
    try testing.expectEqualStrings(default_version, via_managed.install.version);
    // A settings version selects its own install.
    const pinned_other = try plan(a, testing.io, try inputs(&t, .{ .version = "3.1.50" }, null));
    try testing.expect(std.mem.endsWith(u8, pinned_other.install.dir, "3.1.50-tag"));
}

test "plan: strict sources refuse instead of falling back" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    try testing.expectError(error.InheritedEmsdkMissing, plan(a, testing.io, try inputs(&t, .{ .source = .inherited }, null)));
    try testing.expectError(error.InheritedEmsdkMissing, plan(a, testing.io, try inputs(&t, .{ .source = .inherited }, try t.path(&.{"nothing"}))));
    try testing.expectError(error.EmsdkRootInvalid, plan(a, testing.io, try inputs(&t, .{ .source = .root, .root = "missing" }, null)));
    // An inherited EMSDK does not override an explicit root source.
    const ext = try t.path(&.{"ext"});
    try fakeActivated(a, ext);
    try testing.expectError(error.EmsdkRootInvalid, plan(a, testing.io, try inputs(&t, .{ .source = .root, .root = "missing" }, ext)));
    try testing.expect(try plan(a, testing.io, try inputs(&t, .{ .source = .package }, ext)) == .package);
    // A relative root resolves against the project.
    try fakeActivated(a, try t.path(&.{ "project", "sdk" }));
    const rel = try plan(a, testing.io, try inputs(&t, .{ .source = .root, .root = "sdk" }, null));
    try testing.expectEqualStrings(try t.path(&.{ "project", "sdk" }), rel.ready.root);
}

test "ensureManaged installs once, verifies the commit and leaves no staging" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const cache = try t.path(&.{"cache"});
    var fake: Fake = .{};
    const dir = try ensureManaged(a, testing.io, fake.runner(), cache, default_version, false, null);
    try testing.expect(managedComplete(a, testing.io, dir));
    try testing.expectEqual(@as(usize, 1), fake.clones);
    // Complete: a second call (even offline) reuses it.
    _ = try ensureManaged(a, testing.io, fake.runner(), cache, default_version, true, null);
    try testing.expectEqual(@as(usize, 1), fake.clones);
    var parent = try std.Io.Dir.cwd().openDir(testing.io, std.fs.path.dirname(dir).?, .{ .iterate = true });
    defer parent.close(testing.io);
    var it = parent.iterate();
    while (try it.next(testing.io)) |entry| try testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
    // The plan now reports it ready, as the managed source.
    const p = try plan(a, testing.io, try inputs(&t, .{}, null));
    try testing.expectEqual(Source.managed, p.ready.source);
}

test "ensureManaged refuses a mismatched commit, a failed activation and an offline miss" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const cache = try t.path(&.{"cache"});
    var wrong: Fake = .{ .commit = "0000000000000000000000000000000000000000" };
    try testing.expectError(error.EmsdkVerificationFailed, ensureManaged(a, testing.io, wrong.runner(), cache, default_version, false, null));
    var broken: Fake = .{ .fail_activate = true };
    try testing.expectError(error.EmsdkStepFailed, ensureManaged(a, testing.io, broken.runner(), cache, default_version, false, null));
    const dir = try managedDir(a, cache, default_version);
    try testing.expect(!managedComplete(a, testing.io, dir));
    var fake: Fake = .{};
    try testing.expectError(error.EmsdkNotInstalledOffline, ensureManaged(a, testing.io, fake.runner(), cache, default_version, true, null));
    try testing.expectEqual(@as(usize, 0), fake.clones);
    try testing.expectError(error.InvalidEmsdkVersion, ensureManaged(a, testing.io, fake.runner(), cache, "../x", false, null));
}

test "ensureManaged treats a tree without the marker as absent and clears stale staging" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const cache = try t.path(&.{"cache"});
    const dir = try managedDir(a, cache, default_version);
    // An interrupted install: an activated-looking tree with no marker, and
    // a staging sibling left behind.
    try Fake.touch(testing.io, a, &.{ dir, emcc_rel });
    try Fake.touch(testing.io, a, &.{ dir, em_config_name });
    const stale = try std.fmt.allocPrint(a, "{s}.tmp-dead", .{dir});
    try Fake.touch(testing.io, a, &.{ stale, "partial" });
    var fake: Fake = .{};
    _ = try ensureManaged(a, testing.io, fake.runner(), cache, default_version, false, null);
    try testing.expectEqual(@as(usize, 1), fake.clones);
    try testing.expect(!exists(testing.io, stale));
    try testing.expect(managedComplete(a, testing.io, dir));
}

test "package mode activates every fetched emsdk and prefers the one build.zig.zon names" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const target = try t.path(&.{"target"});
    for ([_][]const u8{ "emsdk-a", "emsdk-b" }) |hash| {
        try Fake.touch(testing.io, a, &.{ target, "zig-pkg", hash, launcher_name });
        try Fake.touch(testing.io, a, &.{ target, "zig-pkg", hash, "emsdk.py" });
    }
    // Not an emsdk: no emsdk.py beside the launcher-named file.
    try Fake.touch(testing.io, a, &.{ target, "zig-pkg", "other", launcher_name });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = try t.path(&.{ "target", "build.zig.zon" }),
        .data = ".{ .name = .t, .dependencies = .{ .emsdk = .{ .url = \"x\", .hash = \"emsdk-b\" } } }",
    });
    var fake: Fake = .{};
    const primary = try activatePackages(a, testing.io, fake.runner(), target, try t.path(&.{"cache"}), default_version, false, null);
    try testing.expectEqualStrings(try t.path(&.{ "target", "zig-pkg", "emsdk-b" }), primary);
    try testing.expectEqual(@as(usize, 2), fake.installs);
    for ([_][]const u8{ "emsdk-a", "emsdk-b" }) |hash| try testing.expect(activated(a, testing.io, try t.path(&.{ "target", "zig-pkg", hash })));
    try testing.expect(!hasEmcc(a, testing.io, try t.path(&.{ "target", "zig-pkg", "other" })));
    // Idempotent: nothing left to activate, even offline.
    _ = try activatePackages(a, testing.io, fake.runner(), target, try t.path(&.{"cache"}), default_version, true, null);
    try testing.expectEqual(@as(usize, 2), fake.installs);
    // No fetched emsdk is a clear failure.
    try testing.expectError(error.NoFetchedEmsdk, activatePackages(a, testing.io, fake.runner(), try t.path(&.{"empty"}), try t.path(&.{"cache"}), default_version, false, null));
}

test "the env_file names EMSDK, EM_CONFIG and upstream/emscripten, in contract shape" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const root = try t.path(&.{"sdk"});
    try Fake.touch(testing.io, a, &.{ root, emcc_rel });
    const file = try t.path(&.{"env.json"});
    // Without a config file only EMSDK is set.
    try writeEnvFile(a, testing.io, file, root, null);
    const Shape = struct { set: []const EnvVar, path_prepend: []const []const u8 };
    var parsed = try std.json.parseFromSliceLeaky(Shape, a, try std.Io.Dir.cwd().readFileAlloc(testing.io, file, a, .unlimited), .{});
    try testing.expectEqual(@as(usize, 1), parsed.set.len);
    try Fake.touch(testing.io, a, &.{ root, em_config_name });
    try writeEnvFile(a, testing.io, file, root, null);
    parsed = try std.json.parseFromSliceLeaky(Shape, a, try std.Io.Dir.cwd().readFileAlloc(testing.io, file, a, .unlimited), .{});
    try testing.expectEqualStrings("EMSDK", parsed.set[0].name);
    try testing.expectEqualStrings(root, parsed.set[0].value);
    try testing.expectEqualStrings("EM_CONFIG", parsed.set[1].name);
    try testing.expectEqualStrings(try t.path(&.{ "sdk", em_config_name }), parsed.set[1].value);
    try testing.expectEqual(@as(usize, 1), parsed.path_prepend.len);
    try testing.expectEqualStrings(try t.path(&.{ "sdk", "upstream", "emscripten" }), parsed.path_prepend[0]);
    try testing.expect(std.fs.path.isAbsolute(parsed.path_prepend[0]));
}

test "an emsdk root or inherited EMSDK must be activated: emcc alone is not enough" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    // An interrupted activation: emcc without `.emscripten`.
    const half = try t.path(&.{"half"});
    try Fake.touch(testing.io, a, &.{ half, emcc_rel });
    try testing.expectError(error.EmsdkRootInvalid, plan(a, testing.io, try inputs(&t, .{ .source = .root, .root = half }, null)));
    try testing.expectError(error.EmsdkRootInvalid, plan(a, testing.io, try inputs(&t, .{ .root = half }, null)));
    try testing.expectError(error.InheritedEmsdkMissing, plan(a, testing.io, try inputs(&t, .{ .source = .inherited }, half)));
    // The managed chain skips it rather than handing the build a broken EM_CONFIG.
    try testing.expect(try plan(a, testing.io, try inputs(&t, .{}, half)) == .install);
    try Fake.touch(testing.io, a, &.{ half, em_config_name });
    try testing.expectEqual(Source.inherited, (try plan(a, testing.io, try inputs(&t, .{}, half))).ready.source);
}

test "package mode re-activates a tree activated for another version, or by someone else" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const target = try t.path(&.{"target"});
    const pkg = try t.path(&.{ "target", "zig-pkg", "h" });
    try Fake.touch(testing.io, a, &.{ pkg, launcher_name });
    try Fake.touch(testing.io, a, &.{ pkg, "emsdk.py" });
    // Activated with no record of ours (the CLI 2.x core activates in place too).
    try fakeActivated(a, pkg);
    const cache = try t.path(&.{"cache"});
    var fake: Fake = .{};
    _ = try activatePackages(a, testing.io, fake.runner(), target, cache, "4.0.8", false, null);
    try testing.expectEqual(@as(usize, 1), fake.installs);
    // Recorded 4.0.8: the same version is current, no work.
    _ = try activatePackages(a, testing.io, fake.runner(), target, cache, "4.0.8", false, null);
    try testing.expectEqual(@as(usize, 1), fake.installs);
    // emsdk.version changed to 4.0.9: re-activated, and recorded.
    _ = try activatePackages(a, testing.io, fake.runner(), target, cache, default_version, false, null);
    try testing.expectEqual(@as(usize, 2), fake.installs);
    const recorded = try std.Io.Dir.cwd().readFileAlloc(testing.io, try t.path(&.{ "target", "zig-pkg", "h", package_marker_name }), a, .limited(64));
    try testing.expectEqualStrings(default_version, recorded);
    // Offline, a version change cannot be installed: a clear refusal.
    try testing.expectError(error.EmsdkNotInstalledOffline, activatePackages(a, testing.io, fake.runner(), target, cache, "4.0.8", true, null));
}

test "the launcher and the build get EMSDK_PYTHON on Windows only" {
    const a = testing.allocator;
    const win = try launcherEnv(a, "python3", true);
    defer a.free(win);
    try testing.expectEqual(@as(usize, 1), win.len);
    try testing.expectEqualStrings("EMSDK_PYTHON", win[0].name);
    try testing.expectEqualStrings("python3", win[0].value);
    try testing.expectEqual(@as(usize, 0), (try launcherEnv(a, "python3", false)).len);
    try testing.expectEqual(@as(usize, 0), (try launcherEnv(a, null, true)).len);
    // Through a real managed install: the launcher step receives it on Windows.
    var t = try Tmp.init();
    defer t.deinit();
    var fake: Fake = .{};
    _ = try ensureManaged(t.arena.allocator(), testing.io, fake.runner(), try t.path(&.{"cache"}), default_version, false, "python3");
    if (is_windows) try testing.expectEqualStrings("python3", fake.launcher_python.?) else try testing.expectEqual(@as(?[]const u8, null), fake.launcher_python);
}

test "checkPython accepts only Python 3" {
    var fake: Fake = .{ .python_major = "2" };
    const got = checkPython(testing.allocator, testing.io, fake.runner());
    try testing.expect(got == .python2);
    try testing.expectEqual(@as(?[]const u8, null), findPython(testing.allocator, testing.io, fake.runner()));
    fake.python_major = "3";
    try testing.expect(checkPython(testing.allocator, testing.io, fake.runner()) == .found);
}

test "findPython reports a missing interpreter" {
    var fake: Fake = .{ .has_python = false };
    try testing.expectEqual(@as(?[]const u8, null), findPython(testing.allocator, testing.io, fake.runner()));
    fake.has_python = true;
    try testing.expect(findPython(testing.allocator, testing.io, fake.runner()) != null);
}

test "offline follows the CLI's LABELLE_OFFLINE reading" {
    try testing.expect(!offlineValue(null));
    try testing.expect(!offlineValue(""));
    try testing.expect(!offlineValue("0"));
    try testing.expect(offlineValue("1"));
    try testing.expect(offlineValue("yes"));
}
