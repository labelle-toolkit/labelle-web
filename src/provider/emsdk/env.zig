//! The environment contribution (`env_file`) and binaryen's `wasm-opt`
//! lookup for the export.
const std = @import("std");
const emsdk = @import("../emsdk.zig");
const is_windows = emsdk.is_windows;
const default_version = emsdk.default_version;
const launcher_name = emsdk.launcher_name;
const em_config_name = emsdk.em_config_name;
const emscripten_rel = emsdk.emscripten_rel;
const emcc_rel = emsdk.emcc_rel;
const upstream_bin_rel = emsdk.upstream_bin_rel;
const wasm_opt_name = emsdk.wasm_opt_name;
const launcherEnv = emsdk.launcherEnv;
const exists = emsdk.exists;
const managedDir = emsdk.managedDir;
const EnvVar = emsdk.EnvVar;
const Source = @import("resolve.zig").Source;
const Inputs = @import("resolve.zig").Inputs;
const ensure = @import("resolve.zig").ensure;
const activatePackages = @import("package.zig").activatePackages;
const testing = std.testing;
const Fake = @import("test_support.zig").Fake;
const Tmp = @import("test_support.zig").Tmp;
const fakeActivated = @import("test_support.zig").fakeActivated;
const inputs = @import("test_support.zig").inputs;

pub const Contribution = struct {
    set: []const EnvVar,
    path_prepend: []const []const u8,
};

/// `EMSDK`, `EM_CONFIG` (when the root has one), and `upstream/emscripten`
/// then `upstream/bin` in front of PATH, for every emsdk source. emcc finds
/// clang/wasm-ld through `.emscripten`; `upstream/bin` is on PATH for the
/// tools run outside emcc, i.e. the bundle export's `wasm-opt`.
pub fn contribution(a: std.mem.Allocator, io: std.Io, root: []const u8, python: ?[]const u8, extra: []const EnvVar) !Contribution {
    var set: std.ArrayList(EnvVar) = .empty;
    try set.appendSlice(a, extra);
    try set.append(a, .{ .name = "EMSDK", .value = root });
    const config = try std.fs.path.join(a, &.{ root, em_config_name });
    if (exists(io, config)) try set.append(a, .{ .name = "EM_CONFIG", .value = config });
    // emcc.bat runs `%EMSDK_PYTHON%` when set: the same interpreter as the launcher.
    try set.appendSlice(a, try launcherEnv(a, python, is_windows));
    const emscripten = try std.fs.path.join(a, &.{ root, emscripten_rel });
    const upstream_bin = try std.fs.path.join(a, &.{ root, upstream_bin_rel });
    return .{ .set = set.items, .path_prepend = try a.dupe([]const u8, &.{ emscripten, upstream_bin }) };
}

pub fn writeEnvFile(a: std.mem.Allocator, io: std.Io, path: []const u8, root: []const u8, python: ?[]const u8, extra: []const EnvVar) !void {
    const value = try contribution(a, io, root, python, extra);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// An env_file carrying only `vars` (no toolchain): the `before generate`
/// contribution when the emsdk comes later (`"package"` source) but a
/// generation switch must still reach the assembler.
pub fn writeVarsOnly(a: std.mem.Allocator, io: std.Io, path: []const u8, vars: []const EnvVar) !void {
    const value: Contribution = .{ .set = vars, .path_prepend = &.{} };
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// binaryen's `wasm-opt` in the emsdk these inputs name, when it exists:
/// the export's fallback where PATH lacks `upstream/bin` (a
/// `labelle web export` command gets no toolchain contribution). Tried in
/// the resolution order, without installing or printing: `EMSDK` (the
/// user's, or the one the toolchain hooks contributed), then `emsdk.root`,
/// then a managed install.
pub fn wasmOptPath(a: std.mem.Allocator, io: std.Io, in: Inputs) ?[]const u8 {
    var roots: [3]?[]const u8 = .{ null, null, null };
    if (in.inherited) |root| if (root.len != 0) {
        roots[0] = std.fs.path.resolve(a, &.{ in.project_dir, root }) catch null;
    };
    if (in.emsdk.root) |root| roots[1] = std.fs.path.resolve(a, &.{ in.project_dir, root }) catch null;
    if (in.emsdk.source == .managed) roots[2] = managedDir(a, in.cache_dir, in.version()) catch null;
    for (roots) |maybe| {
        const root = maybe orelse continue;
        const tool = std.fs.path.join(a, &.{ root, upstream_bin_rel, wasm_opt_name }) catch continue;
        if (exists(io, tool)) return tool;
    }
    return null;
}

test "the env_file names EMSDK, EM_CONFIG, upstream/emscripten and upstream/bin, in contract shape" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const root = try t.path(&.{"sdk"});
    try Fake.touch(testing.io, a, &.{ root, emcc_rel });
    const file = try t.path(&.{"env.json"});
    // Without a config file only EMSDK is set.
    try writeEnvFile(a, testing.io, file, root, null, &.{});
    const Shape = struct { set: []const EnvVar, path_prepend: []const []const u8 };
    var parsed = try std.json.parseFromSliceLeaky(Shape, a, try std.Io.Dir.cwd().readFileAlloc(testing.io, file, a, .unlimited), .{});
    try testing.expectEqual(@as(usize, 1), parsed.set.len);
    try Fake.touch(testing.io, a, &.{ root, em_config_name });
    try writeEnvFile(a, testing.io, file, root, null, &.{});
    parsed = try std.json.parseFromSliceLeaky(Shape, a, try std.Io.Dir.cwd().readFileAlloc(testing.io, file, a, .unlimited), .{});
    try testing.expectEqualStrings("EMSDK", parsed.set[0].name);
    try testing.expectEqualStrings(root, parsed.set[0].value);
    try testing.expectEqualStrings("EM_CONFIG", parsed.set[1].name);
    try testing.expectEqualStrings(try t.path(&.{ "sdk", em_config_name }), parsed.set[1].value);
    // emcc's directory first, then binaryen's (`wasm-opt`), both absolute.
    try testing.expectEqual(@as(usize, 2), parsed.path_prepend.len);
    try testing.expectEqualStrings(try t.path(&.{ "sdk", "upstream", "emscripten" }), parsed.path_prepend[0]);
    try testing.expectEqualStrings(try t.path(&.{ "sdk", "upstream", "bin" }), parsed.path_prepend[1]);
    for (parsed.path_prepend) |dir| try testing.expect(std.fs.path.isAbsolute(dir));
}

test "every emsdk source contributes upstream/emscripten then upstream/bin to PATH" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var fake: Fake = .{};
    // Each source resolved the way the toolchain hooks resolve it.
    const ext = try t.path(&.{"external-emsdk"});
    try fakeActivated(a, ext);
    const inherited = (try ensure(a, testing.io, fake.runner(), try inputs(&t, .{ .source = .inherited }, ext))).?.ready;
    const passthrough = (try ensure(a, testing.io, fake.runner(), try inputs(&t, .{}, ext))).?.ready;
    const configured = try t.path(&.{"configured-emsdk"});
    try fakeActivated(a, configured);
    const root = (try ensure(a, testing.io, fake.runner(), try inputs(&t, .{ .source = .root, .root = configured }, null))).?.ready;
    const managed = (try ensure(a, testing.io, fake.runner(), try inputs(&t, .{}, null))).?.ready;
    const target = try t.path(&.{"target"});
    try Fake.touch(testing.io, a, &.{ target, "zig-pkg", "emsdk-h", launcher_name });
    try Fake.touch(testing.io, a, &.{ target, "zig-pkg", "emsdk-h", "emsdk.py" });
    const package = try activatePackages(a, testing.io, fake.runner(), target, try t.path(&.{"cache"}), default_version, false, null);
    try testing.expectEqual(Source.inherited, inherited.source);
    try testing.expectEqual(Source.inherited, passthrough.source);
    try testing.expectEqual(Source.root, root.source);
    try testing.expectEqual(Source.managed, managed.source);
    for ([_][]const u8{ inherited.root, passthrough.root, root.root, managed.root, package }) |sdk| {
        const c = try contribution(a, testing.io, sdk, null, &.{});
        try testing.expectEqual(@as(usize, 2), c.path_prepend.len);
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ sdk, "upstream", "emscripten" }), c.path_prepend[0]);
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ sdk, "upstream", "bin" }), c.path_prepend[1]);
    }
}

test "wasmOptPath finds binaryen in EMSDK, emsdk.root or the managed install, in that order" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const ext = try t.path(&.{"external-emsdk"});
    const configured = try t.path(&.{"configured-emsdk"});
    const managed = try managedDir(a, try t.path(&.{"cache"}), default_version);
    // No wasm-opt anywhere: nothing.
    try testing.expect(wasmOptPath(a, testing.io, try inputs(&t, .{ .root = configured }, ext)) == null);
    try Fake.touch(testing.io, a, &.{ managed, upstream_bin_rel, wasm_opt_name });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ managed, "upstream", "bin", wasm_opt_name }), wasmOptPath(a, testing.io, try inputs(&t, .{}, null)).?);
    // Strict sources never reach for the managed install.
    try testing.expect(wasmOptPath(a, testing.io, try inputs(&t, .{ .source = .inherited }, ext)) == null);
    try Fake.touch(testing.io, a, &.{ configured, upstream_bin_rel, wasm_opt_name });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ configured, "upstream", "bin", wasm_opt_name }), wasmOptPath(a, testing.io, try inputs(&t, .{ .root = configured }, null)).?);
    try Fake.touch(testing.io, a, &.{ ext, upstream_bin_rel, wasm_opt_name });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ ext, "upstream", "bin", wasm_opt_name }), wasmOptPath(a, testing.io, try inputs(&t, .{ .root = configured }, ext)).?);
}

test "extra variables lead the contribution; a vars-only file has no PATH entries (labelle-web#24)" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const switch_var: EnvVar = .{ .name = "LABELLE_WASM_THREADS", .value = "1" };
    const c = try contribution(a, testing.io, "/sdk", null, &.{switch_var});
    try testing.expectEqualStrings("LABELLE_WASM_THREADS", c.set[0].name);
    try testing.expectEqualStrings("EMSDK", c.set[1].name);

    const file = try t.path(&.{"vars.json"});
    try writeVarsOnly(a, testing.io, file, &.{switch_var});
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, file, a, .limited(4096));
    try testing.expectEqualStrings("{\"set\":[{\"name\":\"LABELLE_WASM_THREADS\",\"value\":\"1\"}],\"path_prepend\":[]}", bytes);
}
