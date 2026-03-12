const std = @import("std");

pub const WalkOptions = struct {
    preserve_mode: bool = false,
    preserve_time: bool = false,
};

test "macsync fs skeleton compiles" {
    const options = WalkOptions{};
    try std.testing.expect(!options.preserve_mode);
    try std.testing.expect(!options.preserve_time);
}
