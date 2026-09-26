const std = @import("std");
pub fn build(b: *std.Build) void {
    _ = b.addModule("storage", .{ .root_source_file = b.path("src/web_storage.zig"), .target = b.standardTargetOptions(.{}), .optimize = b.standardOptimizeOption(.{}), .link_libc = true });
}
