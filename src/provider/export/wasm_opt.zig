//! The best-effort `wasm-opt -O3` pass over the exported `.wasm` files.
const std = @import("std");
const exporter = @import("../export.zig");
const FileReport = exporter.FileReport;
const trimTrailingSeps = @import("paths.zig").trimTrailingSeps;
const fileSize = @import("paths.zig").fileSize;

/// Best-effort `wasm-opt -O3` over every top-level `.wasm` in
/// `output_dir`. Returns true if at least one file was optimized.
/// `wasm-opt` is looked up on PATH (where the toolchain hooks put the
/// emsdk's `upstream/bin`), then at `fallback`. Missing everywhere is not
/// an error — the export just ships the un-optimized wasm.
pub fn optimizeWasm(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    files: *std.ArrayList(FileReport),
    fallback: ?[]const u8,
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
                .argv = &.{ exe, "-O3", "--strip-debug", in_path, "-o", out_path },
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
