//! Test doubles shared by the emsdk modules' tests: a fake git/emsdk
//! runner and a scratch directory.
const std = @import("std");
const core = @import("../emsdk.zig");
const settings_mod = @import("../settings.zig");
const testing = std.testing;
const is_windows = core.is_windows;
const default_commit = core.default_commit;
const launcher_name = core.launcher_name;
const em_config_name = core.em_config_name;
const emcc_rel = core.emcc_rel;
const Runner = core.Runner;
const EnvVar = core.EnvVar;
const Inputs = @import("resolve.zig").Inputs;

/// A fake git/emsdk: `clone` lays out a checkout (launcher + emsdk.py),
/// `rev-parse` answers `commit`, `install` creates emcc, `activate` the
/// config. Records how many clones and activations ran.
pub const Fake = struct {
    commit: []const u8 = default_commit,
    clones: usize = 0,
    installs: usize = 0,
    fail_activate: bool = false,
    has_python: bool = true,
    /// What `-c "print(sys.version_info[0])"` answers per command.
    python_major: []const u8 = "3",
    /// `EMSDK_PYTHON` as the last launcher step received it.
    launcher_python: ?[]const u8 = null,

    pub fn runner(self: *Fake) Runner {
        return .{ .ctx = self, .step = step, .capture = capture };
    }

    pub fn touch(io: std.Io, a: std.mem.Allocator, parts: []const []const u8) !void {
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

pub const Tmp = struct {
    dir: testing.TmpDir,
    root: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn init() !Tmp {
        var t: Tmp = .{ .dir = testing.tmpDir(.{}), .root = undefined, .arena = .init(testing.allocator) };
        t.root = try t.dir.dir.realPathFileAlloc(testing.io, ".", t.arena.allocator());
        return t;
    }
    pub fn deinit(t: *Tmp) void {
        t.arena.deinit();
        t.dir.cleanup();
    }
    pub fn path(t: *Tmp, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(t.arena.allocator(), t.root);
        try all.appendSlice(t.arena.allocator(), parts);
        return std.fs.path.join(t.arena.allocator(), all.items);
    }
};

/// An activated-looking emsdk: emcc and the `.emscripten` config.
pub fn fakeActivated(a: std.mem.Allocator, root: []const u8) !void {
    try Fake.touch(testing.io, a, &.{ root, emcc_rel });
    try Fake.touch(testing.io, a, &.{ root, em_config_name });
}

pub fn inputs(t: *Tmp, emsdk: settings_mod.Emsdk, inherited: ?[]const u8) !Inputs {
    return .{ .emsdk = emsdk, .project_dir = try t.path(&.{"project"}), .cache_dir = try t.path(&.{"cache"}), .inherited = inherited, .offline = false };
}
