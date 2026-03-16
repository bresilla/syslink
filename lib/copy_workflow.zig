const std = @import("std");
const client = @import("copy_client.zig");

pub fn openCopy(allocator: std.mem.Allocator, connection: anytype) !client.Client {
    return client.openSubsystem(allocator, connection);
}

pub fn connect(allocator: std.mem.Allocator, connection: anytype) !client.Client {
    var copy_client = try openCopy(allocator, connection);
    errdefer copy_client.close() catch {};
    _ = try copy_client.handshake();
    return copy_client;
}
