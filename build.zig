const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("storage", .{ .root_source_file = b.path("src/web_storage.zig"), .target = target, .optimize = optimize, .link_libc = true });

    _ = b.addModule("labelle_web", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const provider_module = b.createModule(.{ .root_source_file = b.path("src/provider_main.zig"), .target = b.graph.host, .optimize = optimize });
    const provider = b.addExecutable(.{ .name = "labelle-web", .root_module = provider_module });
    b.step("install-provider", "Install provider commands and hooks").dependOn(&b.addInstallArtifact(provider, .{}).step);
    const provider_tests = b.addRunArtifact(b.addTest(.{ .root_module = provider_module }));
    b.step("test-provider", "Test provider packaging, HTTP and wire contract").dependOn(&provider_tests.step);
    const shell = b.addModule("shell", .{ .root_source_file = b.path("src/shell.zig"), .target = target, .optimize = optimize });
    const shell_tests = b.addTest(.{ .root_module = shell });
    const run_shell_tests = b.addRunArtifact(shell_tests);
    const tool = b.addExecutable(.{ .name = "labelle-web-shell", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell_main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    const install = b.addInstallArtifact(tool, .{});
    b.step("install-shell", "Install the host shell staging tool").dependOn(&install.step);
    const run_shell = b.addRunArtifact(tool);
    if (b.args) |args| run_shell.addArgs(args);
    b.step("shell", "Stage a web shell: -- <built-web-directory> [project-web-directory]").dependOn(&run_shell.step);

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
    test_step.dependOn(&run_shell_tests.step);
    test_step.dependOn(&provider_tests.step);
}
