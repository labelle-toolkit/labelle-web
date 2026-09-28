//! `labelle web doctor [--json]`: the `wasm` capability's requirements,
//! ported from labelle-cli `doctor.zig`'s python and emsdk checks. Side
//! effect free: it never installs, and it exits non-zero only when a
//! requirement is missing.
//!
//! `--json` prints one line on stdout: the capability object
//! `{ "id": "wasm", "required", "ok", "items": [python, emsdk, git] }`, each item
//! in the shape labelle-studio's ToolchainGate reads (`id`, `name`, `ok`,
//! `fixable`, `size_mb`, `action`, `detail`, `hint`). Per RFC
//! labelle-cli#466 D7 the core `labelle doctor --json` aggregates these
//! objects into its one document; the web provider owns the `wasm` id.
const std = @import("std");
const emsdk = @import("emsdk.zig");
const stdio = @import("stdio.zig");

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    ok: bool,
    fixable: bool,
    size_mb: u32,
    action: ?[]const u8,
    detail: ?[]const u8,
    hint: ?[]const u8,
};

pub const Capability = struct {
    id: []const u8 = "wasm",
    required: bool = true,
    ok: bool,
    items: []const Item,
};

pub fn checkPython(a: std.mem.Allocator, io: std.Io, runner: emsdk.Runner) Item {
    const check = emsdk.checkPython(a, io, runner);
    return .{
        .id = "python",
        .name = "Python (wasm: emsdk + emcc)",
        .ok = check == .found,
        .fixable = true,
        .size_mb = 25,
        .action = "labelle install python",
        .detail = switch (check) {
            .found => |cmd| std.fmt.allocPrint(a, "`{s}` on PATH (Python 3)", .{cmd}) catch cmd,
            .python2 => |cmd| std.fmt.allocPrint(a, "`{s}` is Python 2", .{cmd}) catch cmd,
            .missing => null,
        },
        .hint = if (check != .found) "run `labelle install python` (managed, ~25 MB) or install Python 3 and put `python3` on PATH" else null,
    };
}

pub fn checkEmsdk(a: std.mem.Allocator, io: std.Io, in: emsdk.Inputs) Item {
    const base: Item = .{ .id = "emsdk", .name = "emsdk toolchain (wasm)", .ok = true, .fixable = false, .size_mb = 0, .action = null, .detail = null, .hint = null };
    const p = emsdk.plan(a, io, in) catch |err| {
        var item = base;
        item.ok = false;
        item.hint = switch (err) {
            error.InheritedEmsdkMissing => "emsdk.source is \"inherited\": set EMSDK to an emsdk holding upstream/emscripten/emcc",
            error.EmsdkRootInvalid => "settings emsdk.root has no upstream/emscripten/emcc",
            else => std.fmt.allocPrint(a, "could not resolve the emsdk ({s})", .{@errorName(err)}) catch "could not resolve the emsdk",
        };
        return item;
    };
    var item = base;
    switch (p) {
        .ready => |r| item.detail = std.fmt.allocPrint(a, "{s}: {s}", .{ r.source.label(), r.root }) catch r.root,
        .install => |i| {
            // Not a failure: the next wasm build provisions it. Offline it
            // cannot, and the build would fail: report that now.
            item.ok = !in.offline;
            item.detail = std.fmt.allocPrint(a, "managed emsdk {s} not installed yet; the next wasm build installs it into {s}", .{ i.version, i.dir }) catch i.dir;
            if (in.offline) item.hint = std.fmt.allocPrint(a, "LABELLE_OFFLINE is set: run `labelle web toolchain install {s}` with network access", .{i.version}) catch null;
        },
        .package => {
            item.detail = "package: the build activates the zig-pkg emsdk in place after generation";
            // Activation downloads the SDK; offline it only works when every
            // fetched tree is already activated for this version.
            const target_dir = emsdk.selectedTargetDir(a, io, in.project_dir, in.target) catch in.project_dir;
            if (in.offline and !(emsdk.packagesReady(a, io, target_dir, in.version()) catch false)) {
                item.ok = false;
                item.detail = std.fmt.allocPrint(a, "package: emsdk {s} is not activated in every emsdk fetched for this target (or none was fetched yet), and activating it needs the network", .{in.version()}) catch "package: activation needs the network";
                item.hint = "LABELLE_OFFLINE is set: build once with network access (or unset LABELLE_OFFLINE) so the fetched emsdk can be activated";
            }
        },
    }
    return item;
}

/// Git, needed only to provision the managed emsdk (`git clone`). An
/// installed managed emsdk, `emsdk.root`, an inherited `EMSDK` or package
/// mode need none, and report ok.
pub fn checkGit(a: std.mem.Allocator, io: std.Io, runner: emsdk.Runner, in: emsdk.Inputs) Item {
    var item: Item = .{ .id = "git", .name = "Git (managed emsdk install)", .ok = true, .fixable = false, .size_mb = 0, .action = null, .detail = null, .hint = null };
    const p = emsdk.plan(a, io, in) catch {
        item.detail = "not needed: no managed install is planned";
        return item;
    };
    if (p != .install) {
        item.detail = "not needed: no managed emsdk install is pending";
        return item;
    }
    if (runner.capture(runner.ctx, io, a, &.{ "git", "--version" }, null) catch null) |out| {
        item.detail = std.mem.trim(u8, out, " \t\r\n");
        return item;
    }
    item.ok = false;
    item.hint = "install Git: the managed emsdk install runs `git clone` (or point EMSDK or settings emsdk.root at an activated emsdk)";
    return item;
}

pub fn run(a: std.mem.Allocator, io: std.Io, runner: emsdk.Runner, in: emsdk.Inputs, json: bool) !bool {
    const items = [_]Item{ checkPython(a, io, runner), checkEmsdk(a, io, in), checkGit(a, io, runner, in) };
    var all = true;
    for (items) |item| all = all and item.ok;
    const cap: Capability = .{ .ok = all, .items = &items };
    if (json) {
        try stdio.json(io, cap);
    } else {
        std.debug.print("\nlabelle web doctor (wasm)\n", .{});
        for (items) |item| {
            std.debug.print("  [{s}] {s}\n", .{ if (item.ok) "  OK  " else " FAIL ", item.name });
            if (item.detail) |d| std.debug.print("           {s}\n", .{d});
            if (item.hint) |h| std.debug.print("           -> {s}\n", .{h});
        }
    }
    return cap.ok;
}

test "package mode offline: unavailable until every fetched emsdk is activated for the version" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(io, ".", a);
    var in: emsdk.Inputs = .{ .emsdk = .{ .source = .package }, .project_dir = project, .cache_dir = project, .inherited = null, .offline = false };
    // Online: the build can activate; fine.
    try testing.expect(checkEmsdk(a, io, in).ok);
    // Offline with nothing fetched: unavailable, with the reason.
    in.offline = true;
    var item = checkEmsdk(a, io, in);
    try testing.expect(!item.ok);
    try testing.expect(std.mem.indexOf(u8, item.hint.?, "LABELLE_OFFLINE") != null);
    // A tree activated for this version but under another backend's target
    // (a leftover) says nothing about the selected one: still unavailable.
    const leftover = ".labelle/raylib_wasm/zig-pkg/h";
    try tmp.dir.createDirPath(io, leftover ++ "/upstream/emscripten");
    for ([_][]const u8{ emsdk.launcher_name, "emsdk.py", emsdk.em_config_name, "upstream/emscripten/" ++ emsdk.emcc_name }) |f|
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ leftover, f }), .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = leftover ++ "/" ++ emsdk.package_marker_name, .data = emsdk.default_version });
    try testing.expect(!checkEmsdk(a, io, in).ok);
    // Selecting that backend makes it the target's tree: ready.
    try tmp.dir.writeFile(io, .{ .sub_path = "project.labelle", .data = ".{ .name = \"g\", .backend = .raylib }" });
    try testing.expect(checkEmsdk(a, io, in).ok);
    try tmp.dir.deleteFile(io, "project.labelle");
    // Fetched but not activated for 4.0.9: still unavailable.
    const pkg = ".labelle/bgfx_wasm/zig-pkg/h";
    try tmp.dir.createDirPath(io, pkg ++ "/upstream/emscripten");
    for ([_][]const u8{ emsdk.launcher_name, "emsdk.py", emsdk.em_config_name, "upstream/emscripten/" ++ emsdk.emcc_name }) |f|
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ pkg, f }), .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = pkg ++ "/" ++ emsdk.package_marker_name, .data = "4.0.8" });
    try testing.expect(!checkEmsdk(a, io, in).ok);
    // Activated for the requested version: ok offline.
    try tmp.dir.writeFile(io, .{ .sub_path = pkg ++ "/" ++ emsdk.package_marker_name, .data = emsdk.default_version });
    item = checkEmsdk(a, io, in);
    try testing.expect(item.ok);
    try testing.expectEqual(@as(?[]const u8, null), item.hint);
}

/// Answers `git --version` or not; everything else fails.
const FakeGit = struct {
    present: bool,
    fn runner(self: *FakeGit) emsdk.Runner {
        return .{ .ctx = self, .step = step, .capture = capture };
    }
    fn step(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: []const []const u8, _: ?[]const u8, _: []const emsdk.EnvVar) anyerror!u8 {
        return 1;
    }
    fn capture(ctx: ?*anyopaque, _: std.Io, a: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!?[]u8 {
        const self: *FakeGit = @ptrCast(@alignCast(ctx.?));
        if (self.present and std.mem.eql(u8, argv[0], "git")) return try a.dupe(u8, "git version 2.45.0\n");
        return null;
    }
};

test "git is required only while a managed install is pending" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const cache = try std.fs.path.join(a, &.{ root, "cache" });
    const in: emsdk.Inputs = .{ .emsdk = .{}, .project_dir = root, .cache_dir = cache, .inherited = null, .offline = false };
    var missing: FakeGit = .{ .present = false };
    var present: FakeGit = .{ .present = true };
    // Nothing installed: the next build clones, so git must exist.
    var item = checkGit(a, io, missing.runner(), in);
    try testing.expect(!item.ok);
    try testing.expect(std.mem.indexOf(u8, item.hint.?, "git clone") != null);
    item = checkGit(a, io, present.runner(), in);
    try testing.expect(item.ok);
    try testing.expectEqualStrings("git version 2.45.0", item.detail.?);
    // Installed in the cache: no clone ahead, git not required.
    const dir = try emsdk.managedDir(a, cache, emsdk.default_version);
    for ([_][]const u8{ emsdk.marker_name, emsdk.em_config_name, "upstream/emscripten/" ++ emsdk.emcc_name }) |f| {
        const path = try std.fs.path.join(a, &.{ dir, f });
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "x" });
    }
    item = checkGit(a, io, missing.runner(), in);
    try testing.expect(item.ok);
    try testing.expectEqual(@as(?[]const u8, null), item.hint);
}

test "the capability object keeps the studio item shape" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .id = "python", .name = "p", .ok = true, .fixable = true, .size_mb = 25, .action = "labelle install python", .detail = null, .hint = null },
        .{ .id = "emsdk", .name = "e", .ok = false, .fixable = false, .size_mb = 0, .action = null, .detail = "d", .hint = "h" },
    };
    const bytes = try std.json.Stringify.valueAlloc(a, Capability{ .ok = false, .items = &items }, .{});
    defer a.free(bytes);
    try std.testing.expectEqualStrings(
        \\{"id":"wasm","required":true,"ok":false,"items":[{"id":"python","name":"p","ok":true,"fixable":true,"size_mb":25,"action":"labelle install python","detail":null,"hint":null},{"id":"emsdk","name":"e","ok":false,"fixable":false,"size_mb":0,"action":null,"detail":"d","hint":"h"}]}
    , bytes);
}
