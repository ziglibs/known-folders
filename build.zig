const std = @import("std");

pub fn build(b: *std.Build) void {
    b.addModule(.{
        .name = "known-folders",
        .source_file = .{ .path = "known-folders.zig" },
    });
}
