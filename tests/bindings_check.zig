//! Compile check for the storage bindings on wasm32-emscripten. Nothing runs
//! here: tests/wasm-boundary exercises the linked EM_JS entry points.
const std = @import("std");
const storage = @import("storage");

// Zig 0.16's default panic handler reaches std.Io.Threaded child-process code
// that does not compile for wasm32-emscripten.
pub const panic = std.debug.no_panic;

export fn labelle_web_bindings_check(id: u32, buf: [*]u8, len: usize) i32 {
    const bytes = buf[0..len];
    const handle = storage.begin("check", 1, "a.json", bytes, len);
    _ = storage.length(id);
    storage.release(handle);
    return storage.status(id) + @intFromBool(storage.copy(id, bytes));
}
