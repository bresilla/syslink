const std = @import("std");
const Allocator = std.mem.Allocator;
const SessionChannel = @import("../channels/session.zig").SessionChannel;
const protocol = @import("protocol.zig");

pub const Client = struct {
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

    pub fn handshake(self: *Self) !u16 {
        const hello = (protocol.Hello{}).encode();
        try self.session.sendData(&hello);

        const response = try self.waitForData(protocol.HANDSHAKE_TIMEOUT_MS);
        defer self.allocator.free(response);

        switch (response[0]) {
            @intFromEnum(protocol.MessageType.ready) => {
                const ready = try protocol.Ready.decode(response);
                self.negotiated_version = ready.version;
                return ready.version;
            },
            @intFromEnum(protocol.MessageType.error_message) => {
                const message = try protocol.decodeError(self.allocator, response);
                defer self.allocator.free(message);
                std.debug.print("macsync handshake rejected: {s}\n", .{message});
                return error.MacsyncHandshakeRejected;
            },
            else => return error.InvalidMacsyncHandshake,
        }
    }

    pub fn close(self: *Self) !void {
        self.session.sendEof() catch {};
        try self.session.close();
    }

    pub fn getNegotiatedVersion(self: *const Self) ?u16 {
        return self.negotiated_version;
    }

    pub fn getSession(self: *Self) *SessionChannel {
        return &self.session;
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

pub fn openSubsystem(allocator: Allocator, connection: anytype) !Client {
    const session = try connection.requestSubsystem("macsync");
    return Client.init(allocator, session);
}
