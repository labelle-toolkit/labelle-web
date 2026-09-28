//! Package mode: every emsdk Zig fetched into `<target_dir>/zig-pkg/` is
//! activated in place, and the selected target dir is found from
//! `project.labelle`.
const std = @import("std");
const emsdk = @import("../emsdk.zig");
const settings_mod = @import("../settings.zig");
const is_windows = emsdk.is_windows;
const default_version = emsdk.default_version;
const layout = emsdk.layout;
const launcher_name = emsdk.launcher_name;
const package_marker_name = emsdk.package_marker_name;
const sep = emsdk.sep;
const Runner = emsdk.Runner;
const exists = emsdk.exists;
const hasEmcc = emsdk.hasEmcc;
const activated = emsdk.activated;
const activateIn = @import("managed.zig").activateIn;
const testing = std.testing;
const Fake = @import("test_support.zig").Fake;
const Tmp = @import("test_support.zig").Tmp;
const fakeActivated = @import("test_support.zig").fakeActivated;

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
/// `default_backend`. The file is parsed as ZON, the way the CLI reads it,
/// so any whitespace or comments around the field are fine and only the
/// top-level `.backend` counts (not one nested in, say, a plugin entry).
/// An unreadable or malformed file (an invalid string escape included, as
/// the CLI's parse rejects it) yields the default.
pub fn projectBackend(a: std.mem.Allocator, io: std.Io, project_dir: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ project_dir, "project.labelle" });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return default_backend;
    return backendFromZon(a, try a.dupeZ(u8, text)) orelse default_backend;
}

/// The top-level `.backend` enum literal of a ZON struct literal, if any.
/// `a` should be an arena: the parse trees are not freed.
fn backendFromZon(a: std.mem.Allocator, source: [:0]const u8) ?[]const u8 {
    const tree = std.zig.Ast.parse(a, source, .zon) catch return null;
    if (tree.errors.len != 0) return null;
    const zoir = std.zig.ZonGen.generate(a, tree, .{}) catch return null;
    if (zoir.hasCompileErrors()) return null;
    const fields = switch (std.zig.Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |s| s,
        else => return null,
    };
    for (fields.names, 0..) |name, i| {
        if (!std.mem.eql(u8, name.get(zoir), "backend")) continue;
        return switch (fields.vals.at(@intCast(i)).get(zoir)) {
            .enum_literal => |lit| a.dupe(u8, lit.get(zoir)) catch null,
            else => null,
        };
    }
    return null;
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

test "projectBackend tolerates tabs, line breaks and comments around the field" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const project = try t.path(&.{"p"});
    try std.Io.Dir.cwd().createDirPath(testing.io, project);
    const file = try t.path(&.{ "p", "project.labelle" });
    for ([_][2][]const u8{
        .{ ".{\n\t.name\t=\t\"demo\",\n\t.backend\t=\t.raylib,\n}\n", "raylib" },
        .{ ".{ .name = \"demo\", .backend\n    =\n    .sokol }", "sokol" },
        .{ ".{\n    .backend = // the web backend\n        .raylib, // trailing\n}", "raylib" },
        .{ ".{ .backend /* no block comments in ZON */ = .raylib }", default_backend },
        .{ ".{ .plugins = .{ .{ .name = \"x\", .backend = .raylib } }, .name = \"demo\" }", default_backend },
        .{ ".{ .plugins = .{ .{ .backend = .raylib } }, .backend = .sokol }", "sokol" },
        .{ ".{ .backend = \"raylib\" }", default_backend },
        .{ ".{ .name = \"bad\\q\", .backend = .sokol }", default_backend },
    }) |case| {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file, .data = case[0] });
        try testing.expectEqualStrings(case[1], try projectBackend(a, testing.io, project));
    }
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
