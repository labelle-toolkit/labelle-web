//! emsdk source resolution: which emsdk a build uses (`plan`), decided
//! without side effects, and `ensure`, which provisions the managed install.
const std = @import("std");
const emsdk = @import("../emsdk.zig");
const settings_mod = @import("../settings.zig");
const default_version = emsdk.default_version;
const em_config_name = emsdk.em_config_name;
const emcc_rel = emsdk.emcc_rel;
const Runner = emsdk.Runner;
const activated = emsdk.activated;
const managedDir = emsdk.managedDir;
const managedComplete = emsdk.managedComplete;
const ensureManaged = @import("managed.zig").ensureManaged;
const testing = std.testing;
const Fake = @import("test_support.zig").Fake;
const Tmp = @import("test_support.zig").Tmp;
const fakeActivated = @import("test_support.zig").fakeActivated;
const inputs = @import("test_support.zig").inputs;

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
