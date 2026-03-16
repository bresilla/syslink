const std = @import("std");

/// SFTP (SSH File Transfer Protocol) subsystem
pub const protocol = @import("sftp_protocol.zig");
pub const attributes = @import("sftp_attributes.zig");
pub const client = @import("sftp_client.zig");
pub const server = @import("sftp_server.zig");
pub const channel = @import("sftp_channel.zig");
pub const channel_adapter = channel;
pub const workflow = @import("sftp_workflow.zig");

// Re-export commonly used types
pub const SftpClient = client.SftpClient;
pub const SftpServer = server.SftpServer;
pub const SftpChannel = channel.SftpChannel;
pub const openSftpChannel = channel.openSftpChannel;

test {
    std.testing.refAllDecls(@This());
}
