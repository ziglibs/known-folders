# Zig Known Folders Project

## Design Goals

- Minimal API surface
- Provide the user with an option to either obtain a directory handle or a path name
- Keep to folders that are available on all operating systems

## API

```zig
pub const KnownFolder = enum {
    home,
    documents,
    pictures,
    music,
    videos,
    desktop,
    downloads,
    public,
    fonts,
    app_menu,
    cache,
    roaming_configuration,
    local_configuration,
    global_configuration,
    data,
    logs,
    runtime,
    executable_dir,
};

pub const Error = error{ ParseError, OutOfMemory };

pub const KnownFolderConfig = struct {
    xdg_force_default: bool = false,
    xdg_on_mac: bool = false,
};

/// Returns a directory handle, or, if the folder does not exist, `null`.
pub fn open(allocator: std.mem.Allocator, folder: KnownFolder, args: std.fs.Dir.OpenOptions) (std.fs.Dir.OpenError || Error)!?std.fs.Dir;

/// Returns the path to the folder or, if the folder does not exist, `null`.
pub fn getPath(allocator: std.mem.Allocator, folder: KnownFolder) Error!?[]const u8;
```

## Installation

> [!NOTE]
> The minimum supported Zig version is `0.14.0`.

Initialize a `zig build` project if you haven't already.

```bash
zig init
```

Add the `known_folders` package to your `build.zig.zon`.

```bash
zig fetch --save git+https://github.com/ziglibs/known-folders.git
```

You can then import `known-folders` in your `build.zig` with:

```zig
const known_folders = b.dependency("known_folders", .{}).module("known-folders");
const exe = b.addExecutable(...);
// This adds the known-folders module to the executable which can then be imported with `@import("known-folders")`
exe.root_module.addImport("known-folders", known_folders);
```

## Configuration

In your root file, add something like this to configure known-folders:

```zig
pub const known_folders_config = .{
    .xdg_on_mac = true,
}
```
