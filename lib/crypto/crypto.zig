const std = @import("std");
const libfast = @import("libfast");

/// Compatibility crypto facade for liblink.
///
/// This module intentionally re-exports shared crypto from libsafe via libfast,
/// while keeping legacy utility namespaces available for callers that still
/// import `liblink.crypto.*` paths.
pub const std_crypto = std.crypto;

/// Shared SSH crypto primitives (canonical implementation in libsafe).
///
/// `ecdh` and `signature` stay behind compatibility wrappers to preserve
/// liblink-local API behavior while delegating crypto internals to libsafe.
pub const ecdh = @import("ecdh.zig");
pub const signature = @import("signature.zig");
pub const hostkey = libfast.ssh_hostkey;

/// Legacy local helpers kept for compatibility.
pub const aead = @import("aead.zig");
pub const hash = @import("hash.zig");
pub const kdf = @import("kdf.zig");

test {
    std.testing.refAllDecls(@This());
}
