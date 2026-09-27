//! Host-tool IO, supplied by std.process.Init; tests use std.testing.io.
const std = @import("std");
pub var io: ?std.Io = null;
pub fn globalIo() std.Io {
    return io orelse if (@import("builtin").is_test) std.testing.io else @panic("provider IO not initialized");
}
