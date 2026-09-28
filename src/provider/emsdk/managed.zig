//! The provider-managed emsdk install under `cache_dir`: locked, staged,
//! commit-verified, activated and renamed into place.
const std = @import("std");
const emsdk = @import("../emsdk.zig");
const settings_mod = @import("../settings.zig");
const is_windows = emsdk.is_windows;
const default_version = emsdk.default_version;
const git_url = emsdk.git_url;
const pinnedCommit = emsdk.pinnedCommit;
const layout = emsdk.layout;
const host_key = emsdk.host_key;
const launcher_name = emsdk.launcher_name;
const em_config_name = emsdk.em_config_name;
const marker_name = emsdk.marker_name;
const emcc_rel = emsdk.emcc_rel;
const Runner = emsdk.Runner;
const launcherEnv = emsdk.launcherEnv;
const launcherArgv = emsdk.launcherArgv;
const exists = emsdk.exists;
const activated = emsdk.activated;
const managedDir = emsdk.managedDir;
const managedComplete = emsdk.managedComplete;
const Source = @import("resolve.zig").Source;
const plan = @import("resolve.zig").plan;
const testing = std.testing;
const Fake = @import("test_support.zig").Fake;
const Tmp = @import("test_support.zig").Tmp;
const inputs = @import("test_support.zig").inputs;

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
pub fn activateIn(a: std.mem.Allocator, io: std.Io, runner: Runner, root: []const u8, version: []const u8, python: ?[]const u8) !void {
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
