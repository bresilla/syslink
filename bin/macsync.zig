const std = @import("std");
const liblink = @import("liblink");

const VERSION = "0.1.0";

pub const std_options: std.Options = .{
    .log_level = .err,
};

fn printHelp() void {
    std.debug.print(
        \\macsync - liblink-native file transfer tool
        \\
        \\USAGE:
        \\    macsync <command> [options]
        \\
        \\COMMANDS:
        \\    probe [user@]host[:port]    Verify macsync subsystem handshake
        \\    version                     Show version information
        \\    help                        Show this help message
        \\
        \\OPTIONS:
        \\    -i, --identity <key>        Use public key authentication
        \\    --strict-host-key           Require host to exist in known hosts
        \\    --accept-new-host-key       Trust on first use (default)
        \\    --replace-trusted-host      Replace stored host key for this host
        \\
        \\NOTES:
        \\    Phase 1 currently exposes only `probe`.
        \\    Push and pull commands land in a later implementation phase.
        \\
    , .{});
}

fn authenticateClient(
    allocator: std.mem.Allocator,
    conn: *liblink.connection.ClientConnection,
    username: []const u8,
    identity_path: ?[]const u8,
) !bool {
    return try liblink.auth.workflow.authenticateClient(allocator, conn, username, .{
        .identity_path = identity_path,
    });
}

fn connectClientWithHostTrust(
    allocator: std.mem.Allocator,
    hostname: []const u8,
    port: u16,
    random: std.Random,
    policy: liblink.connection.HostKeyTrustPolicy,
) !liblink.connection.ClientConnection {
    return liblink.connection.connectClientTrusted(allocator, hostname, port, random, policy);
}

fn printHostKeyFailureGuidance(
    allocator: std.mem.Allocator,
    hostname: []const u8,
    port: u16,
    policy: liblink.connection.HostKeyTrustPolicy,
) void {
    const host_key = liblink.auth.known_hosts.hostKeyForEndpoint(allocator, hostname, port) catch return;
    defer allocator.free(host_key);

    const trusted = liblink.auth.known_hosts.loadFingerprintsForHost(allocator, host_key) catch return;
    defer liblink.auth.known_hosts.freeFingerprints(allocator, trusted);

    std.debug.print("\nHost key entry: {s}\n", .{host_key});
    if (trusted.len == 0) {
        std.debug.print("No matching fingerprint is stored in ~/.ssh/known_hosts.\n", .{});
        if (policy == .accept_new) {
            std.debug.print("This should be accepted on first use. If it is not, the observed fingerprint above is the key detail.\n", .{});
        }
        return;
    }

    std.debug.print("Stored fingerprints in ~/.ssh/known_hosts:\n", .{});
    for (trusted) |fingerprint| {
        std.debug.print("  {s}\n", .{fingerprint});
    }
    if (policy == .accept_new) {
        std.debug.print("`--accept-new-host-key` only trusts unknown hosts. It does not replace an existing fingerprint.\n", .{});
        std.debug.print("Use `--replace-trusted-host` if this host key rotation is expected.\n", .{});
    }
    std.debug.print("Remove or update the `{s}` entry in ~/.ssh/known_hosts if this server key change is expected.\n", .{host_key});
}

fn runProbeCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: Host required\n", .{});
        std.debug.print("Usage: macsync probe [options] [user@]host[:port]\n", .{});
        printHelp();
        std.process.exit(1);
    }

    var identity_path: ?[]const u8 = null;
    var trust_policy: liblink.connection.HostKeyTrustPolicy = .accept_new;
    var host_arg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--identity")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -i requires a key file path\n", .{});
                std.process.exit(1);
            }
            i += 1;
            identity_path = args[i];
        } else if (std.mem.eql(u8, arg, "--strict-host-key")) {
            trust_policy = .strict;
        } else if (std.mem.eql(u8, arg, "--accept-new-host-key")) {
            trust_policy = .accept_new;
        } else if (std.mem.eql(u8, arg, "--replace-trusted-host")) {
            trust_policy = .replace_trusted_host;
        } else if (arg[0] != '-') {
            host_arg = arg;
        }
    }

    if (host_arg == null) {
        std.debug.print("Error: Host required\n", .{});
        std.process.exit(1);
    }

    const endpoint = liblink.network.endpoint.parseUserHostPort(host_arg.?, "root", 2222) catch {
        std.debug.print("Error: Invalid endpoint format\n", .{});
        std.process.exit(1);
    };

    std.debug.print("Connecting to {s}:{d} as {s}...\n", .{ endpoint.host, endpoint.port, endpoint.username });

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const random = prng.random();

    var conn = connectClientWithHostTrust(allocator, endpoint.host, endpoint.port, random, trust_policy) catch |err| {
        std.debug.print("✗ Connection failed: {}\n", .{err});
        if (err == error.UntrustedHostKey) {
            printHostKeyFailureGuidance(allocator, endpoint.host, endpoint.port, trust_policy);
        }
        std.process.exit(1);
    };
    defer conn.deinit();

    const auth_success = authenticateClient(allocator, &conn, endpoint.username, identity_path) catch |err| {
        std.debug.print("✗ Authentication failed: {}\n", .{err});
        std.process.exit(1);
    };

    if (!auth_success) {
        std.debug.print("✗ Authentication failed\n", .{});
        std.process.exit(1);
    }

    var copy_client = conn.openCopy() catch |err| {
        std.debug.print("✗ macsync probe failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer copy_client.close() catch {};

    const version = copy_client.getNegotiatedVersion() orelse liblink.copy.protocol.CURRENT_VERSION;
    std.debug.print("✓ macsync subsystem handshake succeeded (protocol version {})\n", .{version});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "help")) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, command, "version")) {
        std.debug.print("macsync version {s}\n", .{VERSION});
        return;
    }
    if (std.mem.eql(u8, command, "probe")) {
        try runProbeCommand(allocator, args[2..]);
        return;
    }

    std.debug.print("Error: Unknown command '{s}'\n\n", .{command});
    printHelp();
    std.process.exit(1);
}
