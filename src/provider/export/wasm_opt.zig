//! The best-effort `wasm-opt` pass over the exported `.wasm` files.
//! Its level follows `LABELLE_WASM_LINK_OPT` (labelle-bgfx#208): unset keeps
//! the production `-O3`; a CI/preview link level is reused so a fast `-O1`
//! link isn't followed by a slow `-O3` binaryen pass.
const std = @import("std");
const exporter = @import("../export.zig");
const FileReport = exporter.FileReport;
const trimTrailingSeps = @import("paths.zig").trimTrailingSeps;
const fileSize = @import("paths.zig").fileSize;

/// The environment variable the backend hook reads for its emcc link level
/// (labelle-bgfx `backend.hook.zig`, `wasm_link_opt_env`).
pub const link_opt_env = "LABELLE_WASM_LINK_OPT";

/// The `wasm-opt` level used when `LABELLE_WASM_LINK_OPT` is unset: the
/// production export, unchanged.
pub const default_level = "-O3";

/// The `wasm-opt` level for a `LABELLE_WASM_LINK_OPT` value, or null to skip
/// the pass. Unset/empty/`default` keeps `-O3`; `O0` skips it (an unoptimized
/// link stays unoptimized); `O1`..`O3`, `Os`, `Oz` reuse that level. Any other
/// value is an error, matching the hook, which refuses it at configure time.
pub fn levelForLinkOpt(value: ?[]const u8) error{InvalidWasmLinkOpt}!?[]const u8 {
    const raw = value orelse return default_level;
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (v.len == 0 or std.mem.eql(u8, v, "default")) return default_level;
    if (std.mem.eql(u8, v, "O0")) return null;
    const levels = [_][]const u8{ "-O1", "-O2", "-O3", "-Os", "-Oz" };
    for (levels) |l| if (std.mem.eql(u8, v, l[1..])) return l;
    return error.InvalidWasmLinkOpt;
}

/// Best-effort `wasm-opt <level>` (`-O3` for a production export, see
/// `levelForLinkOpt`) over every top-level `.wasm` in `output_dir`.
/// Returns true if at least one file was optimized.
/// `wasm-opt` is looked up on PATH (where the toolchain hooks put the
/// emsdk's `upstream/bin`), then at `fallback`. Missing everywhere is not
/// an error — the export just ships the un-optimized wasm.
pub fn optimizeWasm(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    files: *std.ArrayList(FileReport),
    fallback: ?[]const u8,
    level: []const u8,
) !bool {
    const tools = [_]?[]const u8{ "wasm-opt", fallback };
    var tool: usize = 0;
    const cwd = std.Io.Dir.cwd();
    const scratch = try optimizerScratch(allocator, io, output_dir);
    defer allocator.free(scratch);
    defer cwd.deleteTree(io, scratch) catch {};
    var any = false;
    for (files.items) |*f| {
        if (!std.mem.endsWith(u8, f.rel, ".wasm")) continue;

        const in_path = try std.fs.path.join(allocator, &.{ output_dir, f.rel });
        defer allocator.free(in_path);
        const out_path = try std.fs.path.join(allocator, &.{ scratch, "optimized.wasm" });
        defer allocator.free(out_path);

        // Spawn failure (wasm-opt absent) or IO error: try the next tool;
        // with none left, leave the wasm as-is and stop trying.
        const result = while (tool < tools.len) : (tool += 1) {
            const exe = tools[tool] orelse continue;
            break std.process.run(allocator, io, .{
                .argv = &.{ exe, level, "--strip-debug", in_path, "-o", out_path },
            }) catch continue;
        } else return any;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const ok = switch (result.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (!ok) {
            cwd.deleteFile(io, out_path) catch {};
            continue;
        }

        // Swap the optimized file in.
        cwd.rename(out_path, cwd, in_path, io) catch {
            cwd.deleteFile(io, out_path) catch {};
            continue;
        };
        for ([_][]const u8{ ".gz", ".br" }) |ext| {
            const stale = try std.mem.concat(allocator, u8, &.{ in_path, ext });
            defer allocator.free(stale);
            cwd.deleteFile(io, stale) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        f.after = fileSize(io, in_path);
        any = true;
    }
    return any;
}

/// An exclusively created sibling directory stays outside the shipped tree.
pub fn optimizerScratch(a: std.mem.Allocator, io: std.Io, output: []const u8) ![]const u8 {
    while (true) {
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = try std.fmt.allocPrint(a, "{s}.wasm-opt-{s}", .{ trimTrailingSeps(output), std.fmt.bytesToHex(random, .lower) });
        std.Io.Dir.cwd().createDir(io, name, .default_dir) catch |err| {
            a.free(name);
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        return name;
    }
}

test "levelForLinkOpt: unset keeps the production -O3; levels follow the link" {
    const t = std.testing;
    try t.expectEqualStrings("-O3", (try levelForLinkOpt(null)).?);
    try t.expectEqualStrings("-O3", (try levelForLinkOpt("")).?);
    try t.expectEqualStrings("-O3", (try levelForLinkOpt("default")).?);
    try t.expectEqualStrings("-O1", (try levelForLinkOpt("O1")).?);
    try t.expectEqualStrings("-O2", (try levelForLinkOpt("O2")).?);
    try t.expectEqualStrings("-O3", (try levelForLinkOpt("O3")).?);
    try t.expectEqualStrings("-Os", (try levelForLinkOpt(" Os ")).?);
    try t.expectEqualStrings("-Oz", (try levelForLinkOpt("Oz")).?);
    try t.expectEqual(@as(?[]const u8, null), try levelForLinkOpt("O0"));
    try t.expectError(error.InvalidWasmLinkOpt, levelForLinkOpt("-O1"));
    try t.expectError(error.InvalidWasmLinkOpt, levelForLinkOpt("o1"));
}
