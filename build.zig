const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("known-folders", .{
        .root_source_file = .{ .path = "known-folders.zig" },
    });
}
