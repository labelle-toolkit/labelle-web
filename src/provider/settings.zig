//! The provider-owned settings file (`provider_config` → `config_file`),
//! schema 1. Strict: unknown keys, duplicate keys, wrong types and a
//! missing or unknown `schema_version` are errors, reported before any side
//! effect. Every other key is optional and defaults as shown:
//!
//! ```json
//! { "schema_version": 1, "port": 8080, "open_browser": true, "build_dir": null,
//!   "emsdk": { "version": "4.0.9", "source": "managed", "root": null },
//!   "export": { "platform": "none", "zip": false } }
//! ```
const std = @import("std");
const exporter = @import("export.zig");

pub const schema_version: u32 = 1;

/// Where the emscripten toolchain comes from (`emsdk.zig`).
pub const EmsdkSource = enum {
    /// The default chain: an inherited `EMSDK` whose emcc exists, else
    /// `emsdk.root`, else the provider-managed install in `cache_dir`.
    managed,
    /// Only `emsdk.root` (required).
    root,
    /// Only the inherited `EMSDK` (required).
    inherited,
    /// Activate every emsdk Zig fetched into the target's `zig-pkg/`, in
    /// place, after generation.
    package,
};

pub const Emsdk = struct {
    /// Null: the pinned default (`emsdk.default_version`).
    version: ?[]const u8 = null,
    source: EmsdkSource = .managed,
    /// An existing emsdk (holding `upstream/emscripten/emcc`), absolute or
    /// relative to the project.
    root: ?[]const u8 = null,
};

pub const Export = struct {
    platform: []const u8 = "none",
    zip: bool = false,
};

pub const Settings = struct {
    schema_version: u32,
    port: u16 = 8080,
    open_browser: bool = true,
    build_dir: ?[]const u8 = null,
    emsdk: Emsdk = .{},
    @"export": Export = .{},

    pub fn exportPlatform(self: Settings) !exporter.Platform {
        if (std.mem.eql(u8, self.@"export".platform, "none")) return .none;
        return exporter.parsePlatform(self.@"export".platform) orelse error.InvalidExportPlatform;
    }
};

/// The defaults a project without a settings file gets.
pub const defaults: Settings = .{ .schema_version = schema_version };

/// Parse and validate. The strings live in `a`.
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Settings {
    const value = std.json.parseFromSliceLeaky(Settings, a, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| {
        std.debug.print("labelle-web: invalid settings file: {s}\n", .{@errorName(err)});
        return error.InvalidSettings;
    };
    // std.json also reads an integer from a string ("8080"); the schema
    // does not.
    const tree = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    for ([_][]const u8{ "schema_version", "port" }) |key| {
        if (tree.object.get(key)) |v| if (v != .integer) {
            std.debug.print("labelle-web: invalid settings file: `{s}` must be a number\n", .{key});
            return error.InvalidSettings;
        };
    }
    if (value.schema_version != schema_version) {
        std.debug.print("labelle-web: settings schema_version {d} is not supported (expected {d})\n", .{ value.schema_version, schema_version });
        return error.UnsupportedSettingsSchema;
    }
    if (value.port == 0) return error.InvalidPort;
    _ = try value.exportPlatform();
    if (value.emsdk.version) |v| if (!safeVersion(v)) return error.InvalidEmsdkVersion;
    if (value.emsdk.source == .root and value.emsdk.root == null) {
        std.debug.print("labelle-web: settings emsdk.source is \"root\" but emsdk.root is not set\n", .{});
        return error.MissingEmsdkRoot;
    }
    if (value.emsdk.root) |root| if (root.len == 0) return error.MissingEmsdkRoot;
    return value;
}

/// An emsdk version reaches `emsdk install <version>` and names a cache
/// directory: letters, digits, `.`, `_`, `-`; no leading `-`, no `..`.
pub fn safeVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > 64 or v[0] == '-') return false;
    if (std.mem.indexOf(u8, v, "..") != null) return false;
    for (v) |c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;

test "settings v1: a full document round-trips its values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(),
        \\{ "schema_version": 1, "port": 9000, "open_browser": false, "build_dir": "out",
        \\  "emsdk": { "version": "4.0.10", "source": "root", "root": "/opt/emsdk" },
        \\  "export": { "platform": "github-pages", "zip": true } }
    );
    try testing.expectEqual(@as(u16, 9000), s.port);
    try testing.expect(!s.open_browser);
    try testing.expectEqualStrings("out", s.build_dir.?);
    try testing.expectEqualStrings("4.0.10", s.emsdk.version.?);
    try testing.expectEqual(EmsdkSource.root, s.emsdk.source);
    try testing.expectEqual(exporter.Platform.github_pages, try s.exportPlatform());
    try testing.expect(s.@"export".zip);
}

test "settings v1: only schema_version is required; the rest defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), "{\"schema_version\":1}");
    try testing.expectEqual(@as(u16, 8080), s.port);
    try testing.expect(s.open_browser);
    try testing.expectEqual(EmsdkSource.managed, s.emsdk.source);
    try testing.expectEqual(@as(?[]const u8, null), s.emsdk.version);
    try testing.expectEqual(exporter.Platform.none, try s.exportPlatform());
}

test "settings v1 is strict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{}", // no schema_version
        "{\"port\":8080}", // the v0.2 shape
        "{\"schema_version\":1,\"extra\":true}",
        "{\"schema_version\":1,\"port\":1,\"port\":2}",
        "{\"schema_version\":1,\"emsdk\":{\"source\":\"system\"}}",
        "{\"schema_version\":1,\"emsdk\":{\"verison\":\"4.0.9\"}}",
        "{\"schema_version\":1,\"port\":\"8080\"}",
    }) |bad| {
        if (parse(a, bad)) |_| {
            std.debug.print("accepted: {s}\n", .{bad});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidSettings, err);
    }
    try testing.expectError(error.UnsupportedSettingsSchema, parse(a, "{\"schema_version\":2}"));
    try testing.expectError(error.InvalidPort, parse(a, "{\"schema_version\":1,\"port\":0}"));
    try testing.expectError(error.InvalidExportPlatform, parse(a, "{\"schema_version\":1,\"export\":{\"platform\":\"steam\"}}"));
    try testing.expectError(error.InvalidEmsdkVersion, parse(a, "{\"schema_version\":1,\"emsdk\":{\"version\":\"../x\"}}"));
    try testing.expectError(error.InvalidEmsdkVersion, parse(a, "{\"schema_version\":1,\"emsdk\":{\"version\":\"-rf\"}}"));
    try testing.expectError(error.MissingEmsdkRoot, parse(a, "{\"schema_version\":1,\"emsdk\":{\"source\":\"root\"}}"));
}
