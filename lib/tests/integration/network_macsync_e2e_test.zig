const std = @import("std");
const testing = std.testing;
const liblink = @import("../../liblink.zig");
const network_test_utils = @import("network_test_utils.zig");

const SERVER_PRNG_SEED: u64 = 0x5566_7788;
const CLIENT_PRNG_SEED: u64 = 0x1122_3344;
const TEST_PORT_BASE: u16 = 44_000;

const ServerThreadCtx = network_test_utils.CommonServerThreadCtx;

fn serverThreadMain(ctx: *ServerThreadCtx) void {
    var accepted = network_test_utils.startAndAcceptAuthenticatedServer(ctx, SERVER_PRNG_SEED) catch {
        network_test_utils.markFailed(&ctx.failed);
        return;
    };
    defer accepted.deinit();

    var session_runtime = liblink.server.session_runtime.SessionRuntime.init(
        accepted.conn.allocator,
        network_test_utils.USERNAME,
    ) catch {
        network_test_utils.markFailed(&ctx.failed);
        return;
    };
    defer session_runtime.deinit();

    session_runtime.run(accepted.conn) catch {
        network_test_utils.markFailed(&ctx.failed);
        return;
    };
}

test "Integration: network macsync subsystem handshake e2e" {
    const allocator = testing.allocator;

    try network_test_utils.requireEnvEnabled(allocator, "LIBLINK_NETWORK_MACSYNC_E2E");

    var server_ctx = ServerThreadCtx{
        .allocator = allocator,
        .port = network_test_utils.chooseTestPort(TEST_PORT_BASE),
    };

    const server_thread = try std.Thread.spawn(.{}, serverThreadMain, .{&server_ctx});

    try network_test_utils.waitForServerReady(&server_ctx);

    var client = try network_test_utils.connectAuthenticatedClient(allocator, server_ctx.port, CLIENT_PRNG_SEED);
    defer client.deinit();

    var macsync_client = try client.openCopy();
    defer macsync_client.close() catch {};

    try testing.expectEqual(@as(?u16, liblink.copy.protocol.CURRENT_VERSION), macsync_client.getNegotiatedVersion());

    server_thread.join();
    try testing.expect(!server_ctx.failed.load(.acquire));
}
