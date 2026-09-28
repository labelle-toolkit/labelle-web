//! `labelle web doctor [--json]`: the `wasm` capability's requirements,
//! ported from labelle-cli `doctor.zig`'s python and emsdk checks. Side
//! effect free: it never installs, and it exits non-zero only when a
//! requirement is missing.
//!
//! `--json` prints one line on stdout: the capability object
//! `{ "id": "wasm", "required", "ok", "items": [python, emsdk] }`, each item
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
        .package => item.detail = "package: the build activates the zig-pkg emsdk in place after generation",
    }
    return item;
}

pub fn run(a: std.mem.Allocator, io: std.Io, runner: emsdk.Runner, in: emsdk.Inputs, json: bool) !bool {
    const items = [_]Item{ checkPython(a, io, runner), checkEmsdk(a, io, in) };
    const cap: Capability = .{ .ok = items[0].ok and items[1].ok, .items = &items };
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
