//! Bindings for engine.storage.Web(@import("web_storage.zig")). The selected
//! runtime service must explicitly link web_storage.c; no global registration.
extern "c" fn labelle_blob_begin([*]const u8, u32, u32, [*]const u8, u32, [*]const u8, u32, u32) u32;
extern "c" fn labelle_blob_status(u32) i32;
extern "c" fn labelle_blob_length(u32) u32;
extern "c" fn labelle_blob_copy(u32, [*]u8, u32) i32;
extern "c" fn labelle_blob_release(u32) void;

pub fn begin(namespace: []const u8, kind: u32, name: []const u8, bytes: []const u8, limit: usize) u32 {
    return labelle_blob_begin(namespace.ptr, @intCast(namespace.len), kind, name.ptr, @intCast(name.len), bytes.ptr, @intCast(bytes.len), @intCast(limit));
}
pub const status = labelle_blob_status;
pub const length = labelle_blob_length;
pub const release = labelle_blob_release;
pub fn copy(id: u32, bytes: []u8) bool {
    return labelle_blob_copy(id, bytes.ptr, @intCast(bytes.len)) != 0;
}
