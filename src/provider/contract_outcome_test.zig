//! Wire tests of contract §2 `run.outcome_file` (wire `1.5.0`+, cli#473):
//! required on every `1.5.0` run context — an absolute path on the run
//! replacement, null on every other `run` hook — and absent below `1.5.0`.
const std = @import("std");
const contract = @import("contract.zig");

fn runHook(base: contract.Context, wire: []const u8, phase: contract.Phase) contract.Context {
    var value = contract.hookContext(base, wire, .run);
    value.invocation.phase = phase;
    value.target_dir = value.package_dir;
    if (contract.carriesToolchainContext(wire)) value.cache_dir = value.package_dir;
    if (contract.carriesFinalStep(wire)) value.final_step = .run;
    value.run = .{ .env = &.{}, .args = &.{}, .timeout_ms = 1000 };
    return value;
}

test "1.5.0: run.outcome_file is required on the run replacement and refused on every other run hook" {
    try std.testing.expect(contract.carriesOutcomeContext("1.5.0"));
    try std.testing.expect(!contract.carriesOutcomeContext("1.4.0"));
    const parsed = try contract.parseContext(std.testing.allocator, contract.fixture, false);
    defer parsed.deinit();
    // The replacement: required, and absolute.
    var replacement = runHook(parsed.value, "1.5.0", .replace);
    try std.testing.expectError(error.MissingOutcomeFile, replacement.validate(true));
    replacement.run.?.outcome_file = "relative/outcome";
    try std.testing.expectError(error.InvalidPath, replacement.validate(true));
    replacement.run.?.outcome_file = parsed.value.zig_executable;
    try replacement.validate(true);
    // A before or after hook reports nothing: null only.
    for ([_]contract.Phase{ .before, .after }) |phase| {
        var value = runHook(parsed.value, "1.5.0", phase);
        try value.validate(true);
        value.run.?.outcome_file = parsed.value.zig_executable;
        try std.testing.expectError(error.OutcomeFileNotAllowed, value.validate(true));
    }
    // A 1.4.0 replacement never carries one: its strict decoder rejects it.
    var older = runHook(parsed.value, "1.4.0", .replace);
    try older.validate(true);
    older.run.?.outcome_file = parsed.value.zig_executable;
    try std.testing.expectError(error.UnsupportedContract, older.validate(true));
}

test "1.5.0 wire: run.outcome_file is written and read back; a 1.4.0 wire never has the key" {
    const a = std.testing.allocator;
    const parsed = try contract.parseContext(a, contract.fixture, false);
    defer parsed.deinit();
    var replacement = runHook(parsed.value, "1.5.0", .replace);
    replacement.run.?.outcome_file = parsed.value.zig_executable;
    const wire = try std.json.Stringify.valueAlloc(a, replacement, .{});
    defer a.free(wire);
    const back = try contract.parseContext(a, wire, true);
    defer back.deinit();
    try std.testing.expectEqualStrings(parsed.value.zig_executable, back.value.run.?.outcome_file.?);
    // An after hook writes an explicit null; omitting it is a missing field.
    const after = runHook(parsed.value, "1.5.0", .after);
    const after_wire = try std.json.Stringify.valueAlloc(a, after, .{});
    defer a.free(after_wire);
    try std.testing.expect(std.mem.indexOf(u8, after_wire, "\"outcome_file\":null") != null);
    (try contract.parseContext(a, after_wire, true)).deinit();
    const omitted = try std.mem.replaceOwned(u8, a, after_wire, ",\"outcome_file\":null", "");
    defer a.free(omitted);
    try std.testing.expect(!std.mem.eql(u8, omitted, after_wire));
    try std.testing.expectError(error.MissingField, contract.parseContext(a, omitted, true));
    // 1.4.0: never written, and refused even as null.
    const older = runHook(parsed.value, "1.4.0", .replace);
    const older_wire = try std.json.Stringify.valueAlloc(a, older, .{});
    defer a.free(older_wire);
    try std.testing.expect(std.mem.indexOf(u8, older_wire, "outcome_file") == null);
    (try contract.parseContext(a, older_wire, true)).deinit();
    const smuggled = try std.mem.replaceOwned(u8, a, older_wire, "\"watch\":null", "\"watch\":null,\"outcome_file\":null");
    defer a.free(smuggled);
    try std.testing.expect(!std.mem.eql(u8, smuggled, older_wire));
    try std.testing.expectError(error.UnknownField, contract.parseContext(a, smuggled, true));
}
