const std = @import("std");
const testing = std.testing;
const liblink = @import("../../liblink.zig");

const Duplex = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    client_to_server: std.ArrayListUnmanaged([]u8) = .{},
    server_to_client: std.ArrayListUnmanaged([]u8) = .{},
    closed: bool = false,

    fn deinit(self: *Duplex) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.client_to_server.items) |packet| self.allocator.free(packet);
        for (self.server_to_client.items) |packet| self.allocator.free(packet);
        self.client_to_server.deinit(self.allocator);
        self.server_to_client.deinit(self.allocator);
    }

    fn close(self: *Duplex) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
    }

    fn clientSend(self: *Duplex, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.client_to_server.append(self.allocator, try self.allocator.dupe(u8, data));
    }

    fn clientReceive(self: *Duplex, allocator: std.mem.Allocator) ![]u8 {
        _ = allocator;
        while (true) {
            self.mutex.lock();
            if (self.server_to_client.items.len > 0) {
                const msg = self.server_to_client.orderedRemove(0);
                self.mutex.unlock();
                return msg;
            }
            const done = self.closed;
            self.mutex.unlock();

            if (done) return error.EndOfStream;
            std.Thread.sleep(1_000_000);
        }
    }

    fn serverSend(self: *Duplex, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.server_to_client.append(self.allocator, try self.allocator.dupe(u8, data));
    }

    fn serverReceive(self: *Duplex, allocator: std.mem.Allocator) ![]u8 {
        _ = allocator;
        while (true) {
            self.mutex.lock();
            if (self.client_to_server.items.len > 0) {
                const msg = self.client_to_server.orderedRemove(0);
                self.mutex.unlock();
                return msg;
            }
            const done = self.closed;
            self.mutex.unlock();

            if (done) return error.EndOfStream;
            std.Thread.sleep(1_000_000);
        }
    }
};

fn clientSendHook(ctx: *anyopaque, data: []const u8) !void {
    const duplex: *Duplex = @ptrCast(@alignCast(ctx));
    try duplex.clientSend(data);
}

fn clientReceiveHook(ctx: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const duplex: *Duplex = @ptrCast(@alignCast(ctx));
    return duplex.clientReceive(allocator);
}

fn serverSendHook(ctx: *anyopaque, data: []const u8) !void {
    const duplex: *Duplex = @ptrCast(@alignCast(ctx));
    try duplex.serverSend(data);
}

fn serverReceiveHook(ctx: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const duplex: *Duplex = @ptrCast(@alignCast(ctx));
    return duplex.serverReceive(allocator);
}

const ServerThreadCtx = struct {
    allocator: std.mem.Allocator,
    duplex: *Duplex,
    remote_root: []const u8,
    failed: std.atomic.Value(bool) = .init(false),
};

fn markFailed(flag: *std.atomic.Value(bool)) void {
    flag.store(true, .release);
}

fn serverThreadMain(ctx: *ServerThreadCtx) void {
    var server = liblink.copy.Server.initWithHooks(
        ctx.allocator,
        ctx.duplex,
        serverSendHook,
        serverReceiveHook,
        null,
        .{ .remote_root = ctx.remote_root },
    ) catch {
        markFailed(&ctx.failed);
        return;
    };
    defer server.deinit();

    server.run() catch {
        markFailed(&ctx.failed);
        return;
    };
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

test "Integration: in-process macsync push transfers files and directories" {
    const allocator = testing.allocator;

    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/liblink-macsync-e2e-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_root);
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    const remote_root = try liblink.copy.joinPath(allocator, tmp_root, "remote");
    defer allocator.free(remote_root);
    const source_root = try liblink.copy.joinPath(allocator, tmp_root, "tree");
    defer allocator.free(source_root);
    const nested_dir = try liblink.copy.joinPath(allocator, source_root, "nested");
    defer allocator.free(nested_dir);
    const empty_dir = try liblink.copy.joinPath(allocator, source_root, "empty");
    defer allocator.free(empty_dir);
    const solo_file = try liblink.copy.joinPath(allocator, tmp_root, "solo.txt");
    defer allocator.free(solo_file);

    try std.fs.cwd().makePath(remote_root);
    try std.fs.cwd().makePath(source_root);
    try std.fs.cwd().makePath(nested_dir);
    try std.fs.cwd().makePath(empty_dir);

    {
        var file = try std.fs.cwd().createFile(solo_file, .{});
        defer file.close();
        try file.writeAll("solo-data");
    }
    {
        const file_path = try liblink.copy.joinPath(allocator, source_root, "root.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("root-data");
    }
    {
        const file_path = try liblink.copy.joinPath(allocator, source_root, "nested/deep.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("deep-data");
    }

    var duplex = Duplex{ .allocator = allocator };
    defer duplex.deinit();

    var server_ctx = ServerThreadCtx{
        .allocator = allocator,
        .duplex = &duplex,
        .remote_root = remote_root,
    };

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server_ctx});
    defer {
        duplex.close();
        server_thread.join();
    }

    var client = liblink.copy.Client.initWithHooks(
        allocator,
        &duplex,
        clientSendHook,
        clientReceiveHook,
        null,
    );
    defer client.deinit();

    _ = try client.handshake();
    const stats = try client.pushPaths(
        &[_][]const u8{ solo_file, source_root },
        "incoming",
        .{},
    );

    try testing.expectEqual(@as(u32, 3), stats.file_count);
    try testing.expectEqual(@as(u64, "solo-data".len + "root-data".len + "deep-data".len), stats.total_bytes);

    const remote_solo = try liblink.copy.joinPath(allocator, remote_root, "incoming/solo.txt");
    defer allocator.free(remote_solo);
    const remote_root_file = try liblink.copy.joinPath(allocator, remote_root, "incoming/tree/root.txt");
    defer allocator.free(remote_root_file);
    const remote_nested_file = try liblink.copy.joinPath(allocator, remote_root, "incoming/tree/nested/deep.txt");
    defer allocator.free(remote_nested_file);
    const remote_empty_dir = try liblink.copy.joinPath(allocator, remote_root, "incoming/tree/empty");
    defer allocator.free(remote_empty_dir);

    const solo_contents = try readFileAlloc(allocator, remote_solo);
    defer allocator.free(solo_contents);
    const root_contents = try readFileAlloc(allocator, remote_root_file);
    defer allocator.free(root_contents);
    const nested_contents = try readFileAlloc(allocator, remote_nested_file);
    defer allocator.free(nested_contents);

    try testing.expectEqualStrings("solo-data", solo_contents);
    try testing.expectEqualStrings("root-data", root_contents);
    try testing.expectEqualStrings("deep-data", nested_contents);
    try testing.expectEqual(std.fs.File.Kind.directory, (try std.fs.cwd().statFile(remote_empty_dir)).kind);
    try testing.expect(!server_ctx.failed.load(.acquire));
}

test "Integration: in-process macsync resume completes partial destination" {
    const allocator = testing.allocator;

    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/liblink-macsync-resume-e2e-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_root);
    defer std.fs.cwd().deleteTree(tmp_root) catch {};
    try std.fs.cwd().makePath(tmp_root);

    const remote_root = try liblink.copy.joinPath(allocator, tmp_root, "remote");
    defer allocator.free(remote_root);
    const source_root = try liblink.copy.joinPath(allocator, tmp_root, "payload");
    defer allocator.free(source_root);
    const nested_dir = try liblink.copy.joinPath(allocator, source_root, "nested");
    defer allocator.free(nested_dir);

    try std.fs.cwd().makePath(remote_root);
    try std.fs.cwd().makePath(source_root);
    try std.fs.cwd().makePath(nested_dir);

    {
        const file_path = try liblink.copy.joinPath(allocator, source_root, "alpha.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("alpha-complete");
    }
    {
        const file_path = try liblink.copy.joinPath(allocator, source_root, "nested/beta.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("beta-content-long");
    }

    const resume_dest_root = try liblink.copy.joinPath(allocator, remote_root, "resume/payload");
    defer allocator.free(resume_dest_root);
    const resume_nested_dir = try liblink.copy.joinPath(allocator, resume_dest_root, "nested");
    defer allocator.free(resume_nested_dir);
    try std.fs.cwd().makePath(resume_nested_dir);

    {
        const file_path = try liblink.copy.joinPath(allocator, resume_dest_root, "alpha.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("alpha-complete");
    }
    {
        const file_path = try liblink.copy.joinPath(allocator, resume_dest_root, "nested/beta.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("beta");
    }

    var manifest = try liblink.copy.buildManifestFromPaths(allocator, &[_][]const u8{source_root}, .{});
    defer manifest.deinit(allocator);
    const beta_entry = manifest.findByPath("payload/nested/beta.txt") orelse return error.MissingManifestEntry;

    var duplex = Duplex{ .allocator = allocator };
    defer duplex.deinit();

    var server_ctx = ServerThreadCtx{
        .allocator = allocator,
        .duplex = &duplex,
        .remote_root = remote_root,
    };

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server_ctx});
    defer {
        duplex.close();
        server_thread.join();
    }

    var client = liblink.copy.Client.initWithHooks(
        allocator,
        &duplex,
        clientSendHook,
        clientReceiveHook,
        null,
    );
    defer client.deinit();

    _ = try client.handshake();
    const stats = try client.pushPaths(
        &[_][]const u8{source_root},
        "resume",
        .{},
    );

    try testing.expectEqual(@as(?u32, beta_entry.file_id), stats.resumed_file_id);
    try testing.expectEqual(@as(u64, 4), stats.resumed_offset);

    const alpha_path = try liblink.copy.joinPath(allocator, resume_dest_root, "alpha.txt");
    defer allocator.free(alpha_path);
    const beta_path = try liblink.copy.joinPath(allocator, resume_dest_root, "nested/beta.txt");
    defer allocator.free(beta_path);

    const alpha_contents = try readFileAlloc(allocator, alpha_path);
    defer allocator.free(alpha_contents);
    const beta_contents = try readFileAlloc(allocator, beta_path);
    defer allocator.free(beta_contents);

    try testing.expectEqualStrings("alpha-complete", alpha_contents);
    try testing.expectEqualStrings("beta-content-long", beta_contents);
    try testing.expect(!server_ctx.failed.load(.acquire));
}
