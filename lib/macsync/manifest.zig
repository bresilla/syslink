const std = @import("std");
const wire = @import("../protocol/wire.zig");

pub const CURRENT_VERSION: u16 = 1;

pub const EntryKind = enum(u8) {
    file = 1,
    directory = 2,
};

pub const ResumeState = struct {
    next_file_id: ?u32,
    offset: u64 = 0,
};

pub const Entry = struct {
    file_id: u32 = 0,
    kind: EntryKind,
    relative_path: []u8,
    size: u64 = 0,
    mode: ?u32 = null,
    mtime_ns: ?u64 = null,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
    }
};

pub const Manifest = struct {
    entries: []Entry = &.{},

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| {
            entry.deinit(allocator);
        }
        if (self.entries.len > 0) allocator.free(self.entries);
        self.entries = &.{};
    }

    pub fn encode(self: *const Manifest, allocator: std.mem.Allocator) ![]u8 {
        var size: usize = 2 + 4;
        for (self.entries) |entry| {
            size += 4 + 1 + 1 + 8 + 4 + entry.relative_path.len;
            if (entry.mode != null) size += 4;
            if (entry.mtime_ns != null) size += 8;
        }

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var writer = wire.Writer{ .buffer = buffer };
        try writer.writeBytes(&[_]u8{
            @as(u8, @truncate(CURRENT_VERSION >> 8)),
            @as(u8, @truncate(CURRENT_VERSION)),
        });
        try writer.writeUint32(@intCast(self.entries.len));

        for (self.entries) |entry| {
            var flags: u8 = 0;
            if (entry.mode != null) flags |= 0x01;
            if (entry.mtime_ns != null) flags |= 0x02;

            try writer.writeUint32(entry.file_id);
            try writer.writeByte(@intFromEnum(entry.kind));
            try writer.writeByte(flags);
            try writer.writeUint64(entry.size);
            if (entry.mode) |mode| try writer.writeUint32(mode);
            if (entry.mtime_ns) |mtime_ns| try writer.writeUint64(mtime_ns);
            try writer.writeString(entry.relative_path);
        }

        return buffer;
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Manifest {
        if (data.len < 6) return error.InvalidMacsyncManifest;

        var reader = wire.Reader{ .buffer = data };

        var version_bytes: [2]u8 = undefined;
        try reader.readBytes(&version_bytes);
        const version = std.mem.readInt(u16, &version_bytes, .big);
        if (version != CURRENT_VERSION) return error.UnsupportedMacsyncManifestVersion;

        const entry_count = try reader.readUint32();
        const entries = try allocator.alloc(Entry, entry_count);
        errdefer allocator.free(entries);

        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |*entry| {
                entry.deinit(allocator);
            }
        }

        for (entries) |*entry| {
            const file_id = try reader.readUint32();
            const kind_byte = try reader.readByte();
            const flags = try reader.readByte();
            const size = try reader.readUint64();
            const mode = if ((flags & 0x01) != 0) try reader.readUint32() else null;
            const mtime_ns = if ((flags & 0x02) != 0) try reader.readUint64() else null;
            const relative_path = try reader.readString(allocator);

            entry.* = .{
                .file_id = file_id,
                .kind = std.meta.intToEnum(EntryKind, kind_byte) catch return error.InvalidMacsyncManifestEntry,
                .relative_path = relative_path,
                .size = size,
                .mode = mode,
                .mtime_ns = mtime_ns,
            };
            initialized += 1;
        }

        return .{ .entries = entries };
    }

    pub fn findByPath(self: *const Manifest, relative_path: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.relative_path, relative_path)) return entry;
        }
        return null;
    }

    pub fn findById(self: *const Manifest, file_id: u32) ?*const Entry {
        for (self.entries) |*entry| {
            if (entry.file_id == file_id) return entry;
        }
        return null;
    }
};

test "macsync manifest round-trip preserves metadata" {
    const allocator = std.testing.allocator;

    var manifest = Manifest{
        .entries = try allocator.alloc(Entry, 3),
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
        .relative_path = try allocator.dupe(u8, "tree/a.txt"),
        .size = 10,
        .mtime_ns = 1234,
    };
    manifest.entries[2] = .{
        .file_id = 3,
        .kind = .file,
        .relative_path = try allocator.dupe(u8, "tree/b.txt"),
        .size = 99,
        .mode = 0o100644,
        .mtime_ns = 5678,
    };

    const encoded = try manifest.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try Manifest.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), decoded.entries.len);
    try std.testing.expectEqualStrings("tree/a.txt", decoded.entries[1].relative_path);
    try std.testing.expectEqual(@as(?u32, 0o100644), decoded.entries[2].mode);
    try std.testing.expectEqual(@as(?u64, 5678), decoded.entries[2].mtime_ns);
}
