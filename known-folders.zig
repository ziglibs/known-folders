const std = @import("std");

pub const SpecialFolder = enum {
  home,
  documents,
  pictures,
  music,
  videos,
  templates,
  desktop,
  downloads,
  public,
  fonts,
  app_menu,
  cache,
  roaming_configuration,
  local_configuration,
  data,
  system_folder,
  runtime,
};

// Explicitly define possible errors to make it clearer what callers need to handle
pub const Error = error {
  // TODO: fill this in
	OutOfMemory,
};

/// Returns a directory handle, or, if the folder does not exist, `null`.
pub fn open(allocator: *std.mem.Allocator, folder: SpecialFolder) Error!?std.fs.Dir {
  // TODO: Implement this
  unreachable;
}

/// Returns the path to the folder or, if the folder does not exist, `null`.
pub fn getPath(allocator: *std.mem.Allocator, folder: SpecialFolder) Error!?[]const u8 {
  // TODO: Implement this
  unreachable;
}
