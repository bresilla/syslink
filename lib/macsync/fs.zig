const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub const WalkOptions = struct {
    preserve_mode: bool = false,
    preserve_time: bool = false,
};

pub const SourceRoot = struct {
    source_path: []const u8,
    archive_path: []const u8,
};

const RawMetadata = struct {
    kind: manifest_mod.EntryKind,
    size: u64,
    mode: u32,
    mtime_ns: u64,
};

pub fn buildManifestFromPaths(
    allocator: std.mem.Allocator,
    input_paths: []const []const u8,
    options: WalkOptions,
) !manifest_mod.Manifest {
    const sources = try allocator.alloc(SourceRoot, input_paths.len);
    defer allocator.free(sources);

    var owned_archive_paths = try allocator.alloc([]u8, input_paths.len);
    defer allocator.free(owned_archive_paths);
    @memset(owned_archive_paths, &.{});
    defer {
        for (owned_archive_paths) |path| {
            if (path.len > 0) allocator.free(path);
        }
    }

    for (input_paths, 0..) |input_path, idx| {
        const archive_path = try deriveArchivePath(allocator, input_path);
        owned_archive_paths[idx] = archive_path;
        sources[idx] = .{
            .source_path = input_path,
            .archive_path = archive_path,
        };
    }

    return buildManifestFromSources(allocator, sources, options);
}

pub fn buildManifestFromSources(
    allocator: std.mem.Allocator,
    sources: []const SourceRoot,
    options: WalkOptions,
) !manifest_mod.Manifest {
    var entries = std.ArrayListUnmanaged(manifest_mod.Entry){};
    errdefer {
        for (entries.items) |*entry| {
            entry.deinit(allocator);
        }
        entries.deinit(allocator);
    }

    for (sources) |source| {
        const archive_path = try normalizeArchivePath(allocator, source.archive_path);
        defer allocator.free(archive_path);

        try appendSourceEntries(
            allocator,
            &entries,
            source.source_path,
            archive_path,
            options,
        );
    }

    std.mem.sort(manifest_mod.Entry, entries.items, {}, lessThanEntry);

    for (entries.items, 0..) |*entry, idx| {
        if (idx > 0 and std.mem.eql(u8, entries.items[idx - 1].relative_path, entry.relative_path)) {
            return error.DuplicateManifestPath;
        }
        entry.file_id = @intCast(idx + 1);
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
    };
}

pub fn calculateResumeState(
    allocator: std.mem.Allocator,
    manifest: *const manifest_mod.Manifest,
    destination_root: []const u8,
) !manifest_mod.ResumeState {
    for (manifest.entries) |entry| {
        const absolute_path = try joinPath(allocator, destination_root, entry.relative_path);
        defer allocator.free(absolute_path);

        const metadata = statPath(allocator, absolute_path) catch |err| switch (err) {
            error.FileNotFound => return .{ .next_file_id = entry.file_id, .offset = 0 },
            else => return err,
        };

        switch (entry.kind) {
            .directory => {
                if (metadata.kind != .directory) {
                    return .{ .next_file_id = entry.file_id, .offset = 0 };
                }
            },
            .file => {
                if (metadata.kind != .file) {
                    return .{ .next_file_id = entry.file_id, .offset = 0 };
                }

                if (metadata.size == entry.size) continue;
                if (metadata.size < entry.size) {
                    return .{ .next_file_id = entry.file_id, .offset = metadata.size };
                }

                return .{ .next_file_id = entry.file_id, .offset = 0 };
            },
        }
    }

    return .{ .next_file_id = null, .offset = 0 };
}

fn appendSourceEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(manifest_mod.Entry),
    source_path: []const u8,
    archive_path: []const u8,
    options: WalkOptions,
) !void {
    const metadata = try statPath(allocator, source_path);
    try appendManifestEntry(allocator, entries, archive_path, metadata, options);

    if (metadata.kind == .directory) {
        try appendDirectoryChildren(allocator, entries, source_path, archive_path, options);
    }
}

fn appendDirectoryChildren(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(manifest_mod.Entry),
    source_dir_path: []const u8,
    archive_dir_path: []const u8,
    options: WalkOptions,
) !void {
    var dir = try std.fs.cwd().openDir(source_dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const child_source_path = try joinPath(allocator, source_dir_path, entry.name);
        defer allocator.free(child_source_path);
        const child_archive_path = try joinPath(allocator, archive_dir_path, entry.name);
        defer allocator.free(child_archive_path);

        const metadata = switch (entry.kind) {
            .file => try statPath(allocator, child_source_path),
            .directory => try statPath(allocator, child_source_path),
            .sym_link => return error.UnsupportedSymlink,
            else => return error.UnsupportedSourceKind,
        };

        try appendManifestEntry(allocator, entries, child_archive_path, metadata, options);

        if (metadata.kind == .directory) {
            try appendDirectoryChildren(allocator, entries, child_source_path, child_archive_path, options);
        }
    }
}

fn appendManifestEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(manifest_mod.Entry),
    relative_path: []const u8,
    metadata: RawMetadata,
    options: WalkOptions,
) !void {
    try entries.append(allocator, .{
        .kind = metadata.kind,
        .relative_path = try allocator.dupe(u8, relative_path),
        .size = if (metadata.kind == .file) metadata.size else 0,
        .mode = if (options.preserve_mode) metadata.mode else null,
        .mtime_ns = if (options.preserve_time) metadata.mtime_ns else null,
    });
}

fn statPath(allocator: std.mem.Allocator, path: []const u8) !RawMetadata {
    _ = allocator;

    const stat = std.posix.fstatat(
        std.fs.cwd().fd,
        path,
        std.posix.AT.SYMLINK_NOFOLLOW,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.StatFailed,
    };
    const file_stat = std.fs.File.Stat.fromPosix(stat);

    const kind = switch (file_stat.kind) {
        .file => manifest_mod.EntryKind.file,
        .directory => manifest_mod.EntryKind.directory,
        .sym_link => return error.UnsupportedSymlink,
        else => return error.UnsupportedSourceKind,
    };

    const mtime_ns: u64 = if (file_stat.mtime < 0)
        0
    else
        @intCast(file_stat.mtime);

    return .{
        .kind = kind,
        .size = file_stat.size,
        .mode = @intCast(file_stat.mode),
        .mtime_ns = mtime_ns,
    };
}

fn deriveArchivePath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, input_path, "/");
    const candidate = if (trimmed.len == 0) input_path else trimmed;
    const basename = std.fs.path.basename(candidate);
    if (basename.len == 0 or std.mem.eql(u8, basename, "/")) {
        return error.InvalidSourcePath;
    }
    return normalizeArchivePath(allocator, basename);
}

fn normalizeArchivePath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, raw, '/');
    var wrote_component = false;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.InvalidArchivePath;
        if (wrote_component) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
        wrote_component = true;
    }

    if (!wrote_component) return error.InvalidArchivePath;
    return out.toOwnedSlice(allocator);
}

fn joinPath(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) ![]u8 {
    if (lhs.len == 0) return allocator.dupe(u8, rhs);
    if (rhs.len == 0) return allocator.dupe(u8, lhs);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ lhs, rhs });
}

fn lessThanEntry(_: void, lhs: manifest_mod.Entry, rhs: manifest_mod.Entry) bool {
    return std.mem.lessThan(u8, lhs.relative_path, rhs.relative_path);
}

test "macsync fs builds stable manifest ordering for directory trees" {
    const allocator = std.testing.allocator;

    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/liblink-macsync-fs-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_root);
    defer std.fs.cwd().deleteTree(tmp_root) catch {};

    const source_root = try joinPath(allocator, tmp_root, "source");
    defer allocator.free(source_root);
    const nested_dir = try joinPath(allocator, source_root, "nested");
    defer allocator.free(nested_dir);
    const empty_dir = try joinPath(allocator, source_root, "empty");
    defer allocator.free(empty_dir);
    try std.fs.cwd().makePath(source_root);
    try std.fs.cwd().makePath(nested_dir);
    try std.fs.cwd().makePath(empty_dir);

    {
        const file_path = try joinPath(allocator, source_root, "z-last.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("last");
    }
    {
        const file_path = try joinPath(allocator, source_root, "nested/a-first.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("first");
    }

    var manifest = try buildManifestFromSources(allocator, &[_]SourceRoot{
        .{
            .source_path = source_root,
            .archive_path = "payload",
        },
    }, .{});
    defer manifest.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), manifest.entries.len);
    try std.testing.expectEqualStrings("payload", manifest.entries[0].relative_path);
    try std.testing.expectEqualStrings("payload/empty", manifest.entries[1].relative_path);
    try std.testing.expectEqualStrings("payload/nested", manifest.entries[2].relative_path);
    try std.testing.expectEqualStrings("payload/nested/a-first.txt", manifest.entries[3].relative_path);
    try std.testing.expectEqualStrings("payload/z-last.txt", manifest.entries[4].relative_path);
    try std.testing.expectEqual(@as(u32, 1), manifest.entries[0].file_id);
    try std.testing.expectEqual(@as(u32, 5), manifest.entries[4].file_id);
}

test "macsync fs resume-state matches first incomplete file and offset" {
    const allocator = std.testing.allocator;

    const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/liblink-macsync-resume-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(tmp_root);
    defer std.fs.cwd().deleteTree(tmp_root) catch {};

    const source_root = try joinPath(allocator, tmp_root, "source");
    defer allocator.free(source_root);
    const destination_root = try joinPath(allocator, tmp_root, "dest");
    defer allocator.free(destination_root);
    const nested_source_dir = try joinPath(allocator, source_root, "nested");
    defer allocator.free(nested_source_dir);

    try std.fs.cwd().makePath(source_root);
    try std.fs.cwd().makePath(destination_root);
    try std.fs.cwd().makePath(nested_source_dir);

    {
        const file_path = try joinPath(allocator, source_root, "alpha.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("alpha-complete");
    }
    {
        const file_path = try joinPath(allocator, source_root, "nested/beta.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("beta-content-long");
    }

    var manifest = try buildManifestFromSources(allocator, &[_]SourceRoot{
        .{
            .source_path = source_root,
            .archive_path = "payload",
        },
    }, .{});
    defer manifest.deinit(allocator);

    const encoded = try manifest.encode(allocator);
    defer allocator.free(encoded);
    var decoded = try manifest_mod.Manifest.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    const payload_dir = try joinPath(allocator, destination_root, "payload");
    defer allocator.free(payload_dir);
    const nested_payload_dir = try joinPath(allocator, destination_root, "payload/nested");
    defer allocator.free(nested_payload_dir);
    try std.fs.cwd().makePath(payload_dir);
    try std.fs.cwd().makePath(nested_payload_dir);

    {
        const file_path = try joinPath(allocator, destination_root, "payload/alpha.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("alpha-complete");
    }
    {
        const file_path = try joinPath(allocator, destination_root, "payload/nested/beta.txt");
        defer allocator.free(file_path);
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("beta");
    }

    const resume_state = try calculateResumeState(allocator, &decoded, destination_root);
    const beta_entry = decoded.findByPath("payload/nested/beta.txt") orelse return error.MissingManifestEntry;

    try std.testing.expectEqual(@as(?u32, beta_entry.file_id), resume_state.next_file_id);
    try std.testing.expectEqual(@as(u64, 4), resume_state.offset);
}
