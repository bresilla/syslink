const std = @import("std");
const Allocator = std.mem.Allocator;
const SessionChannel = @import("../channels/session.zig").SessionChannel;
const protocol = @import("protocol.zig");

pub const Server = struct {
    allocator: Allocator,
    session: SessionChannel,
    negotiated_version: ?u16 = null,

    const Self = @This();

    pub fn init(allocator: Allocator, session: SessionChannel) Self {
        return .{
            .allocator = allocator,
            .session = session,
            .negotiated_version = null,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn runNoopHandshake(self: *Self) !u16 {
        const request = try self.waitForData(protocol.HANDSHAKE_TIMEOUT_MS);
        defer self.allocator.free(request);

        const hello = protocol.Hello.decode(request) catch |err| {
            const encoded = try protocol.encodeError(self.allocator, "invalid macsync hello");
            defer self.allocator.free(encoded);
            try self.session.sendData(encoded);
            return err;
        };

        if (hello.version != protocol.CURRENT_VERSION) {
            const encoded = try protocol.encodeError(self.allocator, "unsupported macsync version");
            defer self.allocator.free(encoded);
            try self.session.sendData(encoded);
            return error.UnsupportedMacsyncVersion;
        }

        const ready = (protocol.Ready{ .version = protocol.CURRENT_VERSION }).encode();
        try self.session.sendData(&ready);
        self.negotiated_version = hello.version;
        return hello.version;
    }

    fn waitForData(self: *Self, timeout_ms: u32) ![]u8 {
        const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline_ms) {
            self.session.manager.transport.poll(50) catch {};

            const data = self.session.receiveData() catch |err| switch (err) {
                error.NoData, error.EndOfBuffer => continue,
                else => return err,
            };
            return data;
        }

        return error.MacsyncHandshakeTimeout;
    }
};
