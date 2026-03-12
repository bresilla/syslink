const std = @import("std");
const Allocator = std.mem.Allocator;
const SessionChannel = @import("../channels/session.zig").SessionChannel;
const fs_mod = @import("fs.zig");
const manifest_mod = @import("manifest.zig");
const protocol = @import("protocol.zig");

pub const PushOptions = struct {
    frame_size: usize = 256 * 1024,
    preserve_mode: bool = false,
    preserve_time: bool = false,
};

pub const TransferStats = struct {
    file_count: u32,
    total_bytes: u64,
    resumed_file_id: ?u32 = null,
    resumed_offset: u64 = 0,
};

pub const Client = struct {
    pub const SendFn = *const fn (ctx: *anyopaque, data: []const u8) anyerror!void;
    pub const ReceiveFn = *const fn (ctx: *anyopaque, allocator: Allocator) anyerror![]u8;
    pub const DeinitFn = *const fn (ctx: *anyopaque) void;

    const ChannelRef = struct {
        session: ?SessionChannel = null,
        ctx: ?*anyopaque = null,
        send_fn: ?SendFn = null,
        receive_fn: ?ReceiveFn = null,
        deinit_fn: ?DeinitFn = null,

        fn fromSession(session: SessionChannel) ChannelRef {
            return .{ .session = session };
        }

        fn fromHooks(ctx: *anyopaque, send_fn: SendFn, receive_fn: ReceiveFn, deinit_fn: ?DeinitFn) ChannelRef {
            return .{
                .ctx = ctx,
                .send_fn = send_fn,
                .receive_fn = receive_fn,
                .deinit_fn = deinit_fn,
            };
        }

        fn send(self: *ChannelRef, data: []const u8) !void {
            if (self.send_fn) |f| return f(self.ctx.?, data);
            return self.session.?.sendData(data);
        }

        fn receive(self: *ChannelRef, allocator: Allocator, timeout_ms: u32) ![]u8 {
            if (self.receive_fn) |f| return f(self.ctx.?, allocator);

            const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
            while (std.time.milliTimestamp() < deadline_ms) {
                self.session.?.manager.transport.poll(50) catch {};

                const data = self.session.?.receiveData() catch |err| switch (err) {
                    error.NoData, error.EndOfBuffer => continue,
                    else => return err,
                };
                return data;
            }

            return error.MacsyncTransferTimeout;
        }

        fn close(self: *ChannelRef) !void {
            if (self.session) |*session| {
                session.sendEof() catch {};
                try session.close();
            }
        }

        fn deinit(self: *ChannelRef) void {
            if (self.deinit_fn) |f| f(self.ctx.?);
        }
    };

    allocator: Allocator,
    channel: ChannelRef,
    negotiated_version: ?u16 = null,

    const Self = @This();
    pub const TRANSFER_TIMEOUT_MS: u32 = 30_000;

    pub fn init(allocator: Allocator, session: SessionChannel) Self {
        return .{
            .allocator = allocator,
            .channel = ChannelRef.fromSession(session),
            .negotiated_version = null,
        };
    }

    pub fn initWithHooks(
        allocator: Allocator,
        ctx: *anyopaque,
        send_fn: SendFn,
        receive_fn: ReceiveFn,
        deinit_fn: ?DeinitFn,
    ) Self {
        return .{
            .allocator = allocator,
            .channel = ChannelRef.fromHooks(ctx, send_fn, receive_fn, deinit_fn),
            .negotiated_version = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.channel.deinit();
    }

    pub fn handshake(self: *Self) !u16 {
        const hello = (protocol.Hello{}).encode();
        try self.channel.send(&hello);

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
        try self.channel.close();
    }

    pub fn getNegotiatedVersion(self: *const Self) ?u16 {
        return self.negotiated_version;
    }

    pub fn getSession(self: *Self) *SessionChannel {
        if (self.channel.session == null) @panic("hook-backed macsync client has no session");
        return &self.channel.session.?;
    }

    pub fn pushPaths(
        self: *Self,
        input_paths: []const []const u8,
        destination_root: []const u8,
        options: PushOptions,
    ) !TransferStats {
        var manifest = try fs_mod.buildManifestFromPaths(self.allocator, input_paths, .{
            .preserve_mode = options.preserve_mode,
            .preserve_time = options.preserve_time,
        });
        defer manifest.deinit(self.allocator);

        const request_frame = try (protocol.TransferRequest{
            .kind = .push,
            .destination_root = destination_root,
            .preserve_mode = options.preserve_mode,
            .preserve_time = options.preserve_time,
        }).encode(self.allocator);
        defer self.allocator.free(request_frame);
        try self.channel.send(request_frame);

        const manifest_frame = try protocol.encodeManifestFrame(self.allocator, &manifest);
        defer self.allocator.free(manifest_frame);
        try self.channel.send(manifest_frame);

        const resume_state = try self.readResumeState();
        const total_bytes = totalFileBytes(&manifest);
        const total_files = totalFileCount(&manifest);

        const chunk_buffer = try self.allocator.alloc(u8, options.frame_size);
        defer self.allocator.free(chunk_buffer);

        for (manifest.entries) |entry| {
            if (entry.kind != .file) continue;

            if (resume_state.next_file_id) |resume_file_id| {
                if (entry.file_id < resume_file_id) continue;
            }

            const source_path = try resolveSourcePath(self.allocator, input_paths, entry.relative_path);
            defer self.allocator.free(source_path);

            var file = try std.fs.cwd().openFile(source_path, .{});
            defer file.close();

            var offset: u64 = 0;
            if (resume_state.next_file_id != null and resume_state.next_file_id.? == entry.file_id) {
                offset = resume_state.offset;
                try file.seekTo(offset);
            }

            while (true) {
                const bytes_read = try file.read(chunk_buffer);
                if (bytes_read == 0) break;

                const chunk_frame = try (protocol.FileChunk{
                    .file_id = entry.file_id,
                    .offset = offset,
                    .data = chunk_buffer[0..bytes_read],
                }).encode(self.allocator);
                defer self.allocator.free(chunk_frame);
                try self.channel.send(chunk_frame);

                offset += bytes_read;
                const checkpoint = try self.readCheckpoint();
                if (checkpoint.file_id != entry.file_id or checkpoint.offset < offset) {
                    return error.InvalidMacsyncCheckpoint;
                }
            }

            const done = (protocol.FileDone{
                .file_id = entry.file_id,
                .final_size = entry.size,
            }).encode();
            try self.channel.send(&done);

            const checkpoint = try self.readCheckpoint();
            if (checkpoint.file_id != entry.file_id or checkpoint.offset != entry.size) {
                return error.InvalidMacsyncCheckpoint;
            }
        }

        const complete = (protocol.Complete{
            .file_count = total_files,
            .total_bytes = total_bytes,
        }).encode();
        try self.channel.send(&complete);

        const ack = try self.readComplete();
        if (ack.file_count != total_files or ack.total_bytes != total_bytes) {
            return error.InvalidMacsyncCompletion;
        }

        return .{
            .file_count = total_files,
            .total_bytes = total_bytes,
            .resumed_file_id = resume_state.next_file_id,
            .resumed_offset = resume_state.offset,
        };
    }

    fn waitForData(self: *Self, timeout_ms: u32) ![]u8 {
        return self.channel.receive(self.allocator, timeout_ms) catch |err| switch (err) {
            error.MacsyncTransferTimeout => return error.MacsyncHandshakeTimeout,
            else => return err,
        };
    }

    fn waitForTransferData(self: *Self) ![]u8 {
        return self.channel.receive(self.allocator, TRANSFER_TIMEOUT_MS);
    }

    fn readResumeState(self: *Self) !manifest_mod.ResumeState {
        const response = try self.waitForTransferData();
        defer self.allocator.free(response);

        return switch (response[0]) {
            @intFromEnum(protocol.MessageType.resume_state) => protocol.decodeResumeStateFrame(response),
            @intFromEnum(protocol.MessageType.error_message) => {
                const message = try protocol.decodeError(self.allocator, response);
                defer self.allocator.free(message);
                std.debug.print("macsync transfer rejected: {s}\n", .{message});
                return error.MacsyncTransferRejected;
            },
            else => error.InvalidMacsyncResumeState,
        };
    }

    fn readCheckpoint(self: *Self) !protocol.Checkpoint {
        const response = try self.waitForTransferData();
        defer self.allocator.free(response);

        return switch (response[0]) {
            @intFromEnum(protocol.MessageType.checkpoint) => protocol.Checkpoint.decode(response),
            @intFromEnum(protocol.MessageType.error_message) => {
                const message = try protocol.decodeError(self.allocator, response);
                defer self.allocator.free(message);
                std.debug.print("macsync transfer failed: {s}\n", .{message});
                return error.MacsyncTransferRejected;
            },
            else => error.InvalidMacsyncCheckpoint,
        };
    }

    fn readComplete(self: *Self) !protocol.Complete {
        const response = try self.waitForTransferData();
        defer self.allocator.free(response);

        return switch (response[0]) {
            @intFromEnum(protocol.MessageType.complete) => protocol.Complete.decode(response),
            @intFromEnum(protocol.MessageType.error_message) => {
                const message = try protocol.decodeError(self.allocator, response);
                defer self.allocator.free(message);
                std.debug.print("macsync completion failed: {s}\n", .{message});
                return error.MacsyncTransferRejected;
            },
            else => error.InvalidMacsyncCompletion,
        };
    }

    fn resolveSourcePath(allocator: Allocator, input_paths: []const []const u8, relative_path: []const u8) ![]u8 {
        for (input_paths) |input_path| {
            const archive_root = try fs_mod.deriveArchivePath(allocator, input_path);
            defer allocator.free(archive_root);

            if (std.mem.eql(u8, relative_path, archive_root)) {
                return allocator.dupe(u8, std.mem.trimRight(u8, input_path, "/"));
            }

            const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{archive_root});
            defer allocator.free(prefix);

            if (!std.mem.startsWith(u8, relative_path, prefix)) continue;

            const source_root = blk: {
                const trimmed = std.mem.trimRight(u8, input_path, "/");
                break :blk if (trimmed.len == 0) input_path else trimmed;
            };
            return fs_mod.joinPath(allocator, source_root, relative_path[prefix.len..]);
        }

        return error.MissingMacsyncSourcePath;
    }

    fn totalFileCount(manifest: *const manifest_mod.Manifest) u32 {
        var count: u32 = 0;
        for (manifest.entries) |entry| {
            if (entry.kind == .file) count += 1;
        }
        return count;
    }

    fn totalFileBytes(manifest: *const manifest_mod.Manifest) u64 {
        var total: u64 = 0;
        for (manifest.entries) |entry| {
            if (entry.kind == .file) total += entry.size;
        }
        return total;
    }
};

pub fn openSubsystem(allocator: Allocator, connection: anytype) !Client {
    const session = try connection.requestSubsystem("macsync");
    return Client.init(allocator, session);
}
