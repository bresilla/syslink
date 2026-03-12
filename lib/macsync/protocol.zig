const std = @import("std");
const wire = @import("../protocol/wire.zig");

pub const CURRENT_VERSION: u16 = 1;
pub const HANDSHAKE_TIMEOUT_MS: u32 = 10_000;

pub const MessageType = enum(u8) {
    hello = 1,
    ready = 2,
    error_message = 255,
};

pub const Hello = struct {
    version: u16 = CURRENT_VERSION,

    pub fn encode(self: Hello) [3]u8 {
        var buffer: [3]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.hello);
        std.mem.writeInt(u16, buffer[1..3], self.version, .big);
        return buffer;
    }

    pub fn decode(data: []const u8) !Hello {
        if (data.len != 3 or data[0] != @intFromEnum(MessageType.hello)) {
            return error.InvalidMacsyncHello;
        }

        return .{
            .version = std.mem.readInt(u16, data[1..3], .big),
        };
    }
};

pub const Ready = struct {
    version: u16 = CURRENT_VERSION,

    pub fn encode(self: Ready) [3]u8 {
        var buffer: [3]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.ready);
        std.mem.writeInt(u16, buffer[1..3], self.version, .big);
        return buffer;
    }

    pub fn decode(data: []const u8) !Ready {
        if (data.len != 3 or data[0] != @intFromEnum(MessageType.ready)) {
            return error.InvalidMacsyncReady;
        }

        return .{
            .version = std.mem.readInt(u16, data[1..3], .big),
        };
    }
};

pub fn encodeError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const buffer = try allocator.alloc(u8, 1 + 4 + message.len);
    errdefer allocator.free(buffer);

    buffer[0] = @intFromEnum(MessageType.error_message);
    var writer = wire.Writer{ .buffer = buffer[1..] };
    try writer.writeString(message);
    return buffer;
}

pub fn decodeError(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len < 5 or data[0] != @intFromEnum(MessageType.error_message)) {
        return error.InvalidMacsyncError;
    }

    var reader = wire.Reader{ .buffer = data[1..] };
    return reader.readString(allocator);
}

test "macsync protocol hello round-trip" {
    const hello = Hello{ .version = 7 };
    const encoded = hello.encode();
    const decoded = try Hello.decode(&encoded);
    try std.testing.expectEqual(@as(u16, 7), decoded.version);
}

test "macsync protocol ready round-trip" {
    const ready = Ready{ .version = 9 };
    const encoded = ready.encode();
    const decoded = try Ready.decode(&encoded);
    try std.testing.expectEqual(@as(u16, 9), decoded.version);
}

test "macsync protocol error round-trip" {
    const allocator = std.testing.allocator;
    const encoded = try encodeError(allocator, "version mismatch");
    defer allocator.free(encoded);

    const decoded = try decodeError(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("version mismatch", decoded);
}
