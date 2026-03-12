const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const manifest = @import("manifest.zig");
pub const fs = @import("fs.zig");
pub const client = @import("client.zig");
pub const server = @import("server.zig");
pub const workflow = @import("workflow.zig");

pub const Client = client.Client;
pub const Server = server.Server;
pub const Manifest = manifest.Manifest;
pub const openMacsync = workflow.openMacsync;
pub const connect = workflow.connect;

test {
    std.testing.refAllDecls(@This());
}
