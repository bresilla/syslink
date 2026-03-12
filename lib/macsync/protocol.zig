const std = @import("std");
const wire = @import("../protocol/wire.zig");
const manifest_mod = @import("manifest.zig");

pub const CURRENT_VERSION: u16 = 1;
pub const HANDSHAKE_TIMEOUT_MS: u32 = 10_000;

pub const MessageType = enum(u8) {
    hello = 1,
    ready = 2,
    manifest = 3,
    resume_state = 4,
    file_chunk = 5,
    file_done = 6,
    checkpoint = 7,
    complete = 8,
    transfer_request = 9,
    error_message = 255,
};

pub const TransferKind = enum(u8) {
    push = 1,
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

pub const ResumeState = manifest_mod.ResumeState;

pub const TransferRequest = struct {
    kind: TransferKind,
    destination_root: []const u8,
    preserve_mode: bool = false,
    preserve_time: bool = false,

    pub fn encode(self: TransferRequest, allocator: std.mem.Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, 1 + 1 + 1 + 1 + 4 + self.destination_root.len);
        errdefer allocator.free(buffer);

        buffer[0] = @intFromEnum(MessageType.transfer_request);
        var writer = wire.Writer{ .buffer = buffer[1..] };
        try writer.writeByte(@intFromEnum(self.kind));
        try writer.writeBool(self.preserve_mode);
        try writer.writeBool(self.preserve_time);
        try writer.writeString(self.destination_root);
        return buffer;
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !TransferRequest {
        if (data.len < 8 or data[0] != @intFromEnum(MessageType.transfer_request)) {
            return error.InvalidMacsyncTransferRequest;
        }

        var reader = wire.Reader{ .buffer = data[1..] };
        const kind_byte = try reader.readByte();
        const preserve_mode = try reader.readBool();
        const preserve_time = try reader.readBool();
        const destination_root = try reader.readString(allocator);
        errdefer allocator.free(destination_root);

        return .{
            .kind = std.meta.intToEnum(TransferKind, kind_byte) catch return error.InvalidMacsyncTransferKind,
            .destination_root = destination_root,
            .preserve_mode = preserve_mode,
            .preserve_time = preserve_time,
        };
    }

    pub fn deinit(self: *TransferRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.destination_root);
    }
};

pub const FileChunk = struct {
    file_id: u32,
    offset: u64,
    data: []const u8,

    pub fn encode(self: FileChunk, allocator: std.mem.Allocator) ![]u8 {
        const buffer = try allocator.alloc(u8, 1 + 4 + 8 + 4 + self.data.len);
        errdefer allocator.free(buffer);

        buffer[0] = @intFromEnum(MessageType.file_chunk);
        var writer = wire.Writer{ .buffer = buffer[1..] };
        try writer.writeUint32(self.file_id);
        try writer.writeUint64(self.offset);
        try writer.writeString(self.data);
        return buffer;
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !FileChunk {
        if (data.len < 17 or data[0] != @intFromEnum(MessageType.file_chunk)) {
            return error.InvalidMacsyncFileChunk;
        }

        var reader = wire.Reader{ .buffer = data[1..] };
        const file_id = try reader.readUint32();
        const offset = try reader.readUint64();
        const chunk_data = try reader.readString(allocator);
        errdefer allocator.free(chunk_data);

        return .{
            .file_id = file_id,
            .offset = offset,
            .data = chunk_data,
        };
    }

    pub fn deinit(self: *FileChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const FileDone = struct {
    file_id: u32,
    final_size: u64,

    pub fn encode(self: FileDone) [13]u8 {
        var buffer: [13]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.file_done);
        std.mem.writeInt(u32, buffer[1..5], self.file_id, .big);
        std.mem.writeInt(u64, buffer[5..13], self.final_size, .big);
        return buffer;
    }

    pub fn decode(data: []const u8) !FileDone {
        if (data.len != 13 or data[0] != @intFromEnum(MessageType.file_done)) {
            return error.InvalidMacsyncFileDone;
        }

        return .{
            .file_id = std.mem.readInt(u32, data[1..5], .big),
            .final_size = std.mem.readInt(u64, data[5..13], .big),
        };
    }
};

pub const Checkpoint = struct {
    file_id: u32,
    offset: u64,

    pub fn encode(self: Checkpoint) [13]u8 {
        var buffer: [13]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.checkpoint);
        std.mem.writeInt(u32, buffer[1..5], self.file_id, .big);
        std.mem.writeInt(u64, buffer[5..13], self.offset, .big);
        return buffer;
    }

    pub fn decode(data: []const u8) !Checkpoint {
        if (data.len != 13 or data[0] != @intFromEnum(MessageType.checkpoint)) {
            return error.InvalidMacsyncCheckpoint;
        }

        return .{
            .file_id = std.mem.readInt(u32, data[1..5], .big),
            .offset = std.mem.readInt(u64, data[5..13], .big),
        };
    }
};

pub const Complete = struct {
    file_count: u32,
    total_bytes: u64,

    pub fn encode(self: Complete) [13]u8 {
        var buffer: [13]u8 = undefined;
        buffer[0] = @intFromEnum(MessageType.complete);
        std.mem.writeInt(u32, buffer[1..5], self.file_count, .big);
        std.mem.writeInt(u64, buffer[5..13], self.total_bytes, .big);
        return buffer;
    }

    pub fn decode(data: []const u8) !Complete {
        if (data.len != 13 or data[0] != @intFromEnum(MessageType.complete)) {
            return error.InvalidMacsyncComplete;
        }

        return .{
            .file_count = std.mem.readInt(u32, data[1..5], .big),
            .total_bytes = std.mem.readInt(u64, data[5..13], .big),
        };
    }
};

pub fn encodeManifestFrame(allocator: std.mem.Allocator, manifest: *const manifest_mod.Manifest) ![]u8 {
    const payload = try manifest.encode(allocator);
    defer allocator.free(payload);

    const buffer = try allocator.alloc(u8, 1 + 4 + payload.len);
    errdefer allocator.free(buffer);

    buffer[0] = @intFromEnum(MessageType.manifest);
    var writer = wire.Writer{ .buffer = buffer[1..] };
    try writer.writeString(payload);
    return buffer;
}

pub fn decodeManifestFrame(allocator: std.mem.Allocator, data: []const u8) !manifest_mod.Manifest {
    if (data.len < 5 or data[0] != @intFromEnum(MessageType.manifest)) {
        return error.InvalidMacsyncManifestFrame;
    }

    var reader = wire.Reader{ .buffer = data[1..] };
    const payload = try reader.readString(allocator);
    defer allocator.free(payload);

    return manifest_mod.Manifest.decode(allocator, payload);
}

pub fn encodeResumeStateFrame(allocator: std.mem.Allocator, state: ResumeState) ![]u8 {
    const buffer = try allocator.alloc(u8, 1 + 1 + 4 + 8);
    errdefer allocator.free(buffer);

    buffer[0] = @intFromEnum(MessageType.resume_state);
    var writer = wire.Writer{ .buffer = buffer[1..] };
    try writer.writeBool(state.next_file_id != null);
    try writer.writeUint32(state.next_file_id orelse 0);
    try writer.writeUint64(state.offset);
    return buffer;
}

pub fn decodeResumeStateFrame(data: []const u8) !ResumeState {
    if (data.len != 14 or data[0] != @intFromEnum(MessageType.resume_state)) {
        return error.InvalidMacsyncResumeState;
    }

    var reader = wire.Reader{ .buffer = data[1..] };
    const has_next = try reader.readBool();
    const next_file_id = try reader.readUint32();
    const offset = try reader.readUint64();

    return .{
        .next_file_id = if (has_next) next_file_id else null,
        .offset = offset,
    };
}

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

test "macsync protocol manifest frame round-trip" {
    const allocator = std.testing.allocator;

    var manifest = manifest_mod.Manifest{
        .entries = try allocator.alloc(manifest_mod.Entry, 2),
    };
    defer manifest.deinit(allocator);

    manifest.entries[0] = .{
        .file_id = 1,
        .kind = .directory,
        .relative_path = try allocator.dupe(u8, "tree"),
        .size = 0,
        .mode = 0o040755,
    };
    manifest.entries[1] = .{
        .file_id = 2,
        .kind = .file,
        .relative_path = try allocator.dupe(u8, "tree/file.txt"),
        .size = 12,
        .mtime_ns = 42,
    };

    const frame = try encodeManifestFrame(allocator, &manifest);
    defer allocator.free(frame);

    var decoded = try decodeManifestFrame(allocator, frame);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try std.testing.expectEqualStrings("tree/file.txt", decoded.entries[1].relative_path);
    try std.testing.expectEqual(@as(?u64, 42), decoded.entries[1].mtime_ns);
}

test "macsync protocol resume-state frame round-trip" {
    const allocator = std.testing.allocator;

    const encoded = try encodeResumeStateFrame(allocator, .{
        .next_file_id = 7,
        .offset = 8192,
    });
    defer allocator.free(encoded);

    const decoded = try decodeResumeStateFrame(encoded);
    try std.testing.expectEqual(@as(?u32, 7), decoded.next_file_id);
    try std.testing.expectEqual(@as(u64, 8192), decoded.offset);
}

test "macsync protocol file chunk round-trip" {
    const allocator = std.testing.allocator;

    const encoded = try (FileChunk{
        .file_id = 3,
        .offset = 128,
        .data = "payload",
    }).encode(allocator);
    defer allocator.free(encoded);

    var decoded = try FileChunk.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), decoded.file_id);
    try std.testing.expectEqualStrings("payload", decoded.data);
}

test "macsync protocol transfer request round-trip" {
    const allocator = std.testing.allocator;

    const encoded = try (TransferRequest{
        .kind = .push,
        .destination_root = "incoming",
        .preserve_mode = true,
        .preserve_time = false,
    }).encode(allocator);
    defer allocator.free(encoded);

    var decoded = try TransferRequest.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(.push, decoded.kind);
    try std.testing.expect(decoded.preserve_mode);
    try std.testing.expect(!decoded.preserve_time);
    try std.testing.expectEqualStrings("incoming", decoded.destination_root);
}
