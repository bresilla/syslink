const std = @import("std");
const client = @import("client.zig");

pub fn openMacsync(allocator: std.mem.Allocator, connection: anytype) !client.Client {
    return client.openSubsystem(allocator, connection);
}

pub fn connect(allocator: std.mem.Allocator, connection: anytype) !client.Client {
    var macsync_client = try openMacsync(allocator, connection);
    errdefer macsync_client.close() catch {};
    _ = try macsync_client.handshake();
    return macsync_client;
}
