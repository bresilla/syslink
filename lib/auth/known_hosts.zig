const std = @import("std");
const libfast = @import("libfast");

pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.HomeNotSet,
        else => return err,
    };
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.ssh/known_hosts", .{home});
}

pub fn hostKeyForEndpoint(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    // Bracket IPv6-style hosts to avoid ambiguity with host:port separator.
    if (std.mem.indexOfScalar(u8, host, ':') != null and !(host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')) {
        return std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port });
    }
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
}

pub fn loadFingerprintsForHost(allocator: std.mem.Allocator, host_key: []const u8) ![][]u8 {
    const path = try defaultPath(allocator);
    defer allocator.free(path);

    return loadFingerprintsForHostAtPath(allocator, path, host_key);
}

pub fn loadFingerprintsForHostAtPath(allocator: std.mem.Allocator, path: []const u8, host_key: []const u8) ![][]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 512 * 1024);
    defer allocator.free(content);

    var list = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (list.items) |fp| allocator.free(fp);
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const fingerprint = try loadFingerprintFromLine(allocator, line, host_key);
        if (fingerprint) |fp| {
            try list.append(allocator, fp);
        }
    }

    return list.toOwnedSlice(allocator);
}

const ParsedHostKey = struct {
    host: []const u8,
    port: []const u8,
    bracketed: bool,
};

fn loadFingerprintFromLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    host_key: []const u8,
) !?[]u8 {
    var parts = std.mem.tokenizeAny(u8, line, " \t");
    const host_field = parts.next() orelse return null;
    if (!hostFieldMatches(host_field, host_key)) return null;

    const second = parts.next() orelse return null;
    if (std.mem.startsWith(u8, second, "SHA256:")) {
        return try allocator.dupe(u8, second);
    }

    if (!std.mem.eql(u8, second, "ssh-ed25519")) {
        return null;
    }

    const key_b64 = parts.next() orelse return null;
    return fingerprintFromOpenSshEd25519(allocator, key_b64) catch null;
}

fn hostFieldMatches(host_field: []const u8, host_key: []const u8) bool {
    var hosts = std.mem.splitScalar(u8, host_field, ',');
    while (hosts.next()) |entry| {
        if (hostEntryMatches(entry, host_key)) return true;
    }
    return false;
}

fn hostEntryMatches(entry: []const u8, host_key: []const u8) bool {
    if (std.mem.eql(u8, entry, host_key)) return true;

    const parsed = parseHostKey(host_key) orelse return false;

    if (std.mem.eql(u8, parsed.port, "22") and std.mem.eql(u8, entry, parsed.host)) {
        return true;
    }

    if (parsed.bracketed) return false;

    if (entry.len != parsed.host.len + parsed.port.len + 3) return false;
    if (entry[0] != '[' or entry[parsed.host.len + 1] != ']' or entry[parsed.host.len + 2] != ':') {
        return false;
    }

    return std.mem.eql(u8, entry[1 .. 1 + parsed.host.len], parsed.host) and
        std.mem.eql(u8, entry[parsed.host.len + 3 ..], parsed.port);
}

fn parseHostKey(host_key: []const u8) ?ParsedHostKey {
    if (host_key.len == 0) return null;

    if (host_key[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_key, ']') orelse return null;
        if (close + 2 > host_key.len or host_key[close + 1] != ':') return null;
        return .{
            .host = host_key[1..close],
            .port = host_key[close + 2 ..],
            .bracketed = true,
        };
    }

    const colon = std.mem.lastIndexOfScalar(u8, host_key, ':') orelse return null;
    if (colon == 0 or colon + 1 >= host_key.len) return null;

    return .{
        .host = host_key[0..colon],
        .port = host_key[colon + 1 ..],
        .bracketed = false,
    };
}

fn fingerprintFromOpenSshEd25519(allocator: std.mem.Allocator, key_b64: []const u8) ![]u8 {
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(key_b64) catch return error.InvalidBase64;
    const blob = try allocator.alloc(u8, decoded_size);
    defer allocator.free(blob);

    std.base64.standard.Decoder.decode(blob, key_b64) catch return error.InvalidBase64;
    const host_key_blob = blob[0..decoded_size];

    try libfast.ssh_hostkey.validate_ed25519_host_key_blob(host_key_blob);
    return libfast.ssh_hostkey.fingerprint_sha256(allocator, host_key_blob);
}

pub fn freeFingerprints(allocator: std.mem.Allocator, fingerprints: [][]u8) void {
    for (fingerprints) |fp| allocator.free(fp);
    allocator.free(fingerprints);
}

pub fn addFingerprint(allocator: std.mem.Allocator, host_key: []const u8, fingerprint: []const u8) !void {
    const path = try defaultPath(allocator);
    defer allocator.free(path);

    return addFingerprintAtPath(allocator, path, host_key, fingerprint);
}

pub fn replaceFingerprint(allocator: std.mem.Allocator, host_key: []const u8, fingerprint: []const u8) !void {
    const path = try defaultPath(allocator);
    defer allocator.free(path);

    return replaceFingerprintAtPath(allocator, path, host_key, fingerprint);
}

pub fn addFingerprintAtPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    host_key: []const u8,
    fingerprint: []const u8,
) !void {
    const existing = try loadFingerprintsForHostAtPath(allocator, path, host_key);
    defer freeFingerprints(allocator, existing);

    for (existing) |fp| {
        if (std.mem.eql(u8, fp, fingerprint)) return;
    }

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    const line = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ host_key, fingerprint });
    defer allocator.free(line);
    try file.writeAll(line);
}

pub fn replaceFingerprintAtPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    host_key: []const u8,
    fingerprint: []const u8,
) !void {
    const content = blk: {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, ""),
            else => return err,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 512 * 1024);
    };
    defer allocator.free(content);

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, &std.ascii.whitespace);
        if (line.len == 0) {
            if (line_raw.len != 0) {
                try output.appendSlice(allocator, line_raw);
                try output.append(allocator, '\n');
            }
            continue;
        }

        if (line[0] != '#') {
            var parts = std.mem.tokenizeAny(u8, line, " \t");
            const host_field = parts.next() orelse "";
            if (hostFieldMatches(host_field, host_key)) continue;
        }

        try output.appendSlice(allocator, line_raw);
        try output.append(allocator, '\n');
    }

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();

    if (output.items.len > 0) {
        try file.writeAll(output.items);
    }

    const line = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ host_key, fingerprint });
    defer allocator.free(line);
    try file.writeAll(line);
}

test "known_hosts host key endpoint formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const h1 = try hostKeyForEndpoint(allocator, "example.com", 2222);
    defer allocator.free(h1);
    try testing.expectEqualStrings("example.com:2222", h1);

    const h2 = try hostKeyForEndpoint(allocator, "2001:db8::1", 2222);
    defer allocator.free(h2);
    try testing.expectEqualStrings("[2001:db8::1]:2222", h2);
}

test "known_hosts add and load by explicit path" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/liblink-known-hosts-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try addFingerprintAtPath(allocator, tmp_path, "example.com:2222", "SHA256:abc");
    try addFingerprintAtPath(allocator, tmp_path, "example.com:2222", "SHA256:abc"); // dedupe
    try addFingerprintAtPath(allocator, tmp_path, "example.com:2222", "SHA256:def");

    const fps = try loadFingerprintsForHostAtPath(allocator, tmp_path, "example.com:2222");
    defer freeFingerprints(allocator, fps);

    try testing.expectEqual(@as(usize, 2), fps.len);
    try testing.expectEqualStrings("SHA256:abc", fps[0]);
    try testing.expectEqualStrings("SHA256:def", fps[1]);
}

test "known_hosts loads fingerprint from OpenSSH ed25519 entry" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/liblink-known-hosts-openssh-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const public_key: [32]u8 = [_]u8{0x42} ** 32;
    const host_key_blob = try libfast.ssh_hostkey.encode_ed25519_host_key_blob(allocator, &public_key);
    defer allocator.free(host_key_blob);

    const expected = try libfast.ssh_hostkey.fingerprint_sha256(allocator, host_key_blob);
    defer allocator.free(expected);

    const b64_len = std.base64.standard.Encoder.calcSize(host_key_blob.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, host_key_blob);

    const line = try std.fmt.allocPrint(
        allocator,
        "[example.com]:2222 ssh-ed25519 {s} comment\n",
        .{b64},
    );
    defer allocator.free(line);

    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = line });

    const fps = try loadFingerprintsForHostAtPath(allocator, tmp_path, "example.com:2222");
    defer freeFingerprints(allocator, fps);

    try testing.expectEqual(@as(usize, 1), fps.len);
    try testing.expectEqualStrings(expected, fps[0]);
}

test "known_hosts replace rewrites matching host entries" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/liblink-known-hosts-replace-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const initial =
        \\# comment
        \\example.com:2222 SHA256:old-a
        \\[example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJC
        \\other.example:2222 SHA256:keep-me
        \\
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = initial });

    try replaceFingerprintAtPath(allocator, tmp_path, "example.com:2222", "SHA256:new-fp");

    const updated = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 4096);
    defer allocator.free(updated);

    try testing.expect(std.mem.indexOf(u8, updated, "example.com:2222 SHA256:old-a") == null);
    try testing.expect(std.mem.indexOf(u8, updated, "[example.com]:2222 ssh-ed25519") == null);
    try testing.expect(std.mem.indexOf(u8, updated, "other.example:2222 SHA256:keep-me") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "example.com:2222 SHA256:new-fp") != null);
}
