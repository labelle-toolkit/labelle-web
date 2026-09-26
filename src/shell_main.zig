//! Explicit staging tool until web-provider build/export/serve extraction lands.
const std = @import("std");
const shell = @import("shell.zig");

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer args.deinit();
    _ = args.skip();
    const output_path = args.next() orelse {
        std.debug.print("usage: labelle-web-shell <built-web-directory> [project-web-directory]\n", .{});
        return 2;
    };
    const project_path = args.next();
    if (args.next() != null) return error.TooManyArguments;
    const output = try std.Io.Dir.cwd().openDir(init.io, output_path, .{});
    defer output.close(init.io);
    const project = if (project_path) |path| try std.Io.Dir.cwd().openDir(init.io, path, .{}) else null;
    defer if (project) |dir| dir.close(init.io);
    _ = try shell.stage(init.arena.allocator(), init.io, output, project);
    return 0;
}
