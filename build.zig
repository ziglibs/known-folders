const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("known-folders", .{
        .source_file = .{ .path = "known-folders.zig" },
    });
}
