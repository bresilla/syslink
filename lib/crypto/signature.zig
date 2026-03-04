const std = @import("std");
const libfast = @import("libfast");

/// Ed25519 signature wrappers delegated to libsafe via libfast.

pub const KeyPair = struct {
    public_key: [32]u8,
    private_key: [64]u8,

    pub fn generate(random: std.Random) KeyPair {
        const key_pair = libfast.ssh_signature.KeyPair.generate(random);
        return .{
            .public_key = key_pair.public_key,
            .private_key = key_pair.private_key,
        };
    }
};

pub fn signEd25519(data: []const u8, private_key: *const [64]u8, signature: *[64]u8) void {
    libfast.ssh_signature.signEd25519(data, private_key, signature) catch unreachable;
}

pub fn sign(data: []const u8, private_key: *const [64]u8) [64]u8 {
    return libfast.ssh_signature.sign(data, private_key) catch unreachable;
}

pub fn verifyEd25519(data: []const u8, signature: *const [64]u8, public_key: *const [32]u8) bool {
    return libfast.ssh_signature.verifyEd25519(data, signature, public_key);
}

test "sign and verify delegates" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const key_pair = KeyPair.generate(random);

    const data = "test message";
    const signature = sign(data, &key_pair.private_key);

    try std.testing.expect(verifyEd25519(data, &signature, &key_pair.public_key));
}
