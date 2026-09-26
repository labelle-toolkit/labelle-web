const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("storage", .{ .root_source_file = b.path("src/web_storage.zig"), .target = target, .optimize = optimize, .link_libc = true });

    // The bindings only link in a wasm32-emscripten build, so `test` compiles
    // them for that target on any host. The EM_JS runtime is covered by
    // tests/web-storage (Node) and tests/wasm-boundary (emcc).
    const wasm = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
    const check_storage = b.createModule(.{ .root_source_file = b.path("src/web_storage.zig"), .target = wasm, .optimize = .ReleaseSmall, .link_libc = true });
    const check = b.addObject(.{ .name = "bindings_check", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/bindings_check.zig"),
        .target = wasm,
        .optimize = .ReleaseSmall,
        .link_libc = true,
        .imports = &.{.{ .name = "storage", .module = check_storage }},
    }) });
    const test_step = b.step("test", "Compile-check the storage bindings for wasm32-emscripten");
    _ = check.getEmittedBin(); // run codegen too, not only analysis
    test_step.dependOn(&check.step);
}
