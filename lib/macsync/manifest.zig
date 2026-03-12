const std = @import("std");

pub const Entry = struct {
    file_id: u32,
    relative_path: []const u8,
    size: u64,
};

pub const Manifest = struct {
    entries: []const Entry = &.{},
};

test "macsync manifest skeleton compiles" {
    const manifest = Manifest{};
    try std.testing.expectEqual(@as(usize, 0), manifest.entries.len);
}
