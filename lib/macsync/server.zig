const std = @import("std");
const Allocator = std.mem.Allocator;
const SessionChannel = @import("../channels/session.zig").SessionChannel;
const client_mod = @import("client.zig");
const fs_mod = @import("fs.zig");
const manifest_mod = @import("manifest.zig");
const protocol = @import("protocol.zig");

pub const Server = struct {
    pub const SendFn = client_mod.Client.SendFn;
    pub const ReceiveFn = client_mod.Client.ReceiveFn;
    pub const DeinitFn = client_mod.Client.DeinitFn;

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

        fn deinit(self: *ChannelRef) void {
            if (self.deinit_fn) |f| f(self.ctx.?);
        }
    };

    pub const Options = struct {
        remote_root: []const u8 = ".",
    };

    allocator: Allocator,
    channel: ChannelRef,
    remote_root: []u8,
    negotiated_version: ?u16 = null,

    const Self = @This();
    pub const TRANSFER_TIMEOUT_MS: u32 = 30_000;

    pub fn init(allocator: Allocator, session: SessionChannel) !Self {
        return initWithOptions(allocator, session, .{});
    }

    pub fn initWithOptions(allocator: Allocator, session: SessionChannel, options: Options) !Self {
        const remote_root = try normalizeRootPath(allocator, options.remote_root);
        errdefer allocator.free(remote_root);

        return .{
            .allocator = allocator,
            .channel = ChannelRef.fromSession(session),
            .remote_root = remote_root,
            .negotiated_version = null,
        };
    }

    pub fn initWithHooks(
        allocator: Allocator,
        ctx: *anyopaque,
        send_fn: SendFn,
        receive_fn: ReceiveFn,
        deinit_fn: ?DeinitFn,
        options: Options,
    ) !Self {
        const remote_root = try normalizeRootPath(allocator, options.remote_root);
        errdefer allocator.free(remote_root);

        return .{
            .allocator = allocator,
            .channel = ChannelRef.fromHooks(ctx, send_fn, receive_fn, deinit_fn),
            .remote_root = remote_root,
            .negotiated_version = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.remote_root);
        self.channel.deinit();
    }

    pub fn runNoopHandshake(self: *Self) !u16 {
        const request = try self.waitForData(protocol.HANDSHAKE_TIMEOUT_MS);
        defer self.allocator.free(request);

        const hello = protocol.Hello.decode(request) catch |err| {
            try self.sendError("invalid macsync hello");
            return err;
        };

        if (hello.version != protocol.CURRENT_VERSION) {
            try self.sendError("unsupported macsync version");
            return error.UnsupportedMacsyncVersion;
        }

        const ready = (protocol.Ready{ .version = protocol.CURRENT_VERSION }).encode();
        try self.channel.send(&ready);
        self.negotiated_version = hello.version;
        return hello.version;
    }

    pub fn run(self: *Self) !void {
        _ = self.runNoopHandshake() catch |err| switch (err) {
            error.EndOfStream, error.ConnectionClosed, error.StreamClosed => return,
            else => return err,
        };

        const request_frame = self.waitForTransferData() catch |err| switch (err) {
            error.EndOfStream, error.ConnectionClosed, error.StreamClosed => return,
            else => return err,
        };
        defer self.allocator.free(request_frame);

        var request = try protocol.TransferRequest.decode(self.allocator, request_frame);
        defer request.deinit(self.allocator);

        switch (request.kind) {
            .push => try self.handlePush(&request),
        }
    }

    fn handlePush(self: *Self, request: *const protocol.TransferRequest) !void {
        const destination_root = try self.resolveDestinationRoot(request.destination_root);
        defer self.allocator.free(destination_root);
        try std.fs.cwd().makePath(destination_root);

        const manifest_frame = try self.waitForTransferData();
        defer self.allocator.free(manifest_frame);

        var manifest = try protocol.decodeManifestFrame(self.allocator, manifest_frame);
        defer manifest.deinit(self.allocator);

        try self.ensureDirectories(&manifest, destination_root);

        const resume_state = try fs_mod.calculateResumeState(self.allocator, &manifest, destination_root);
        const resume_frame = try protocol.encodeResumeStateFrame(self.allocator, resume_state);
        defer self.allocator.free(resume_frame);
        try self.channel.send(resume_frame);

        try self.receivePushStream(destination_root, &manifest);
    }

    fn receivePushStream(
        self: *Self,
        destination_root: []const u8,
        manifest: *const manifest_mod.Manifest,
    ) !void {
        var active_file_id: ?u32 = null;
        var active_file: ?std.fs.File = null;
        defer {
            if (active_file) |*file| file.close();
        }

        while (true) {
            const frame = try self.waitForTransferData();
            defer self.allocator.free(frame);

            switch (frame[0]) {
                @intFromEnum(protocol.MessageType.file_chunk) => {
                    var chunk = try protocol.FileChunk.decode(self.allocator, frame);
                    defer chunk.deinit(self.allocator);

                    const entry = manifest.findById(chunk.file_id) orelse {
                        try self.sendError("unknown macsync file id");
                        return error.UnknownMacsyncFileId;
                    };
                    if (entry.kind != .file) {
                        try self.sendError("macsync chunk target is not a file");
                        return error.InvalidMacsyncFileChunk;
                    }

                    if (active_file_id == null or active_file_id.? != chunk.file_id) {
                        if (active_file) |*file| file.close();
                        active_file = try self.openDestinationFile(destination_root, entry.relative_path);
                        active_file_id = chunk.file_id;
                    }

                    try active_file.?.pwriteAll(chunk.data, chunk.offset);
                    try self.sendCheckpoint(chunk.file_id, chunk.offset + chunk.data.len);
                },
                @intFromEnum(protocol.MessageType.file_done) => {
                    const done = try protocol.FileDone.decode(frame);
                    const entry = manifest.findById(done.file_id) orelse {
                        try self.sendError("unknown macsync file id");
                        return error.UnknownMacsyncFileId;
                    };
                    if (entry.kind != .file) {
                        try self.sendError("macsync completion target is not a file");
                        return error.InvalidMacsyncFileDone;
                    }

                    if (active_file_id == null or active_file_id.? != done.file_id) {
                        if (active_file) |*file| file.close();
                        active_file = try self.openDestinationFile(destination_root, entry.relative_path);
                        active_file_id = done.file_id;
                    }

                    try active_file.?.setEndPos(done.final_size);
                    active_file.?.close();
                    active_file = null;
                    active_file_id = null;
                    try self.sendCheckpoint(done.file_id, done.final_size);
                },
                @intFromEnum(protocol.MessageType.complete) => {
                    const complete = try protocol.Complete.decode(frame);
                    const expected = protocol.Complete{
                        .file_count = totalFileCount(manifest),
                        .total_bytes = totalFileBytes(manifest),
                    };
                    if (complete.file_count != expected.file_count or complete.total_bytes != expected.total_bytes) {
                        try self.sendError("macsync completion summary mismatch");
                        return error.InvalidMacsyncCompletion;
                    }

                    const ack = expected.encode();
                    try self.channel.send(&ack);
                    return;
                },
                @intFromEnum(protocol.MessageType.error_message) => return error.MacsyncTransferRejected,
                else => {
                    try self.sendError("unexpected macsync message");
                    return error.InvalidMacsyncMessage;
                },
            }
        }
    }

    fn ensureDirectories(
        self: *Self,
        manifest: *const manifest_mod.Manifest,
        destination_root: []const u8,
    ) !void {
        for (manifest.entries) |entry| {
            if (entry.kind != .directory) continue;

            const full_path = try fs_mod.joinPath(self.allocator, destination_root, entry.relative_path);
            defer self.allocator.free(full_path);
            try std.fs.cwd().makePath(full_path);
        }
    }

    fn openDestinationFile(self: *Self, destination_root: []const u8, relative_path: []const u8) !std.fs.File {
        const full_path = try fs_mod.joinPath(self.allocator, destination_root, relative_path);
        defer self.allocator.free(full_path);

        if (std.fs.path.dirname(full_path)) |dir_name| {
            try std.fs.cwd().makePath(dir_name);
        }

        return std.fs.cwd().openFile(full_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => std.fs.cwd().createFile(full_path, .{
                .read = true,
                .truncate = false,
            }),
            else => err,
        };
    }

    fn resolveDestinationRoot(self: *Self, requested_root: []const u8) ![]u8 {
        if (requested_root.len == 0 or std.mem.eql(u8, requested_root, ".")) {
            return self.allocator.dupe(u8, self.remote_root);
        }

        const normalized_requested = try normalizeRootPath(self.allocator, requested_root);
        errdefer self.allocator.free(normalized_requested);

        if (std.fs.path.isAbsolute(normalized_requested)) {
            if (!std.mem.eql(u8, self.remote_root, ".")) {
                return error.AbsoluteMacsyncDestinationNotAllowed;
            }
            return normalized_requested;
        }

        if (std.mem.eql(u8, self.remote_root, ".")) return normalized_requested;

        const combined = try fs_mod.joinPath(self.allocator, self.remote_root, normalized_requested);
        self.allocator.free(normalized_requested);
        return combined;
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

    fn sendCheckpoint(self: *Self, file_id: u32, offset: u64) !void {
        const checkpoint = (protocol.Checkpoint{
            .file_id = file_id,
            .offset = offset,
        }).encode();
        try self.channel.send(&checkpoint);
    }

    fn sendError(self: *Self, message: []const u8) !void {
        const encoded = try protocol.encodeError(self.allocator, message);
        defer self.allocator.free(encoded);
        try self.channel.send(encoded);
    }

    fn normalizeRootPath(allocator: Allocator, root: []const u8) ![]u8 {
        if (root.len == 0) return allocator.dupe(u8, ".");
        if (std.mem.eql(u8, root, ".")) return allocator.dupe(u8, ".");
        if (std.mem.eql(u8, root, "/")) return allocator.dupe(u8, "/");

        const trimmed = std.mem.trimRight(u8, root, "/");
        if (trimmed.len == 0) return allocator.dupe(u8, "/");
        return allocator.dupe(u8, trimmed);
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
