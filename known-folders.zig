const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

pub const KnownFolder = enum {
    /// Windows default: `%SystemDrive%\Users\%USERNAME%`
    ///   MacOS default: `$HOME`
    ///    *nix default: `$HOME`
    home,
    /// Windows default: `%USERPROFILE%\Documents`
    ///   MacOS default: `$HOME/Documents`
    ///    *nix default: `$HOME/Documents`
    ///   XDG directory: `XDG_DOCUMENTS_DIR`
    documents,
    /// Windows default: `%USERPROFILE%\Pictures`
    ///   MacOS default: `$HOME/Pictures`
    ///    *nix default: `$HOME/Pictures`
    ///   XDG directory: `XDG_PICTURES_DIR`
    pictures,
    /// Windows default: `%USERPROFILE%\Music`
    ///   MacOS default: `$HOME/Music`
    ///    *nix default: `$HOME/Music`
    ///   XDG directory: `XDG_MUSIC_DIR`
    music,
    /// Windows default: `%USERPROFILE%\Videos`
    ///   MacOS default: `$HOME/Movies`
    ///    *nix default: `$HOME/Videos`
    ///   XDG directory: `XDG_VIDEOS_DIR`
    videos,
    /// Windows default: `%USERPROFILE%\Desktop`
    ///   MacOS default: `$HOME/Desktop`
    ///    *nix default: `$HOME/Desktop`
    ///   XDG directory: `XDG_DESKTOP_DIR`
    desktop,
    /// Windows default: `%USERPROFILE%\Downloads`
    ///   MacOS default: `$HOME/Downloads`
    ///    *nix default: `$HOME/Downloads`
    ///   XDG directory: `XDG_DOWNLOAD_DIR`
    downloads,
    /// Windows default: `%PUBLIC%` (`%SystemDrive%\Users\Public`)
    ///   MacOS default: `$HOME/Public`
    ///    *nix default: `$HOME/Public`
    ///   XDG directory: `XDG_PUBLICSHARE_DIR`
    public,
    /// Windows default: `%windir%\Fonts`
    ///   MacOS default: `$HOME/Library/Fonts`
    ///    *nix default: `$HOME/.local/share/fonts`
    ///   XDG directory: `XDG_DATA_HOME/fonts`
    fonts,
    /// Windows default: `%APPDATA%\Microsoft\Windows\Start Menu`
    ///   MacOS default: `$HOME/Applications`
    ///    *nix default: `$HOME/.local/share/applications`
    ///   XDG directory: `XDG_DATA_HOME/applications`
    app_menu,
    /// The base directory relative to which user-specific non-essential (cached) data should be written.
    ///
    /// Windows:       `%LOCALAPPDATA%\Temp`
    ///   MacOS default: HOME/Library/Caches`
    ///    *nix default: HOME/.cache`
    ///   XDG directory: `XDG_CACHE_HOME`
    cache,
    /// The base directory relative to which user-specific configuration files should be written.
    ///
    /// Windows default: %APPDATA% (%USERPROFILE%\AppData\Roaming)
    ///   MacOS default: `$HOME/Library/Preferences`
    ///    *nix default: `$HOME/.config`
    ///   XDG directory: `XDG_CONFIG_HOME`
    roaming_configuration,
    /// The base directory relative to which user-specific configuration files should be written.
    ///
    /// Windows default: `%LOCALAPPDATA%` (`%USERPROFILE%\AppData\Local`)
    ///   MacOS default: `$HOME/Library/Application Support`
    ///    *nix default: `$HOME/.config`
    ///   XDG directory: `XDG_CONFIG_HOME`
    local_configuration,
    /// The base directory relative to which global configuration files should be searched.
    ///
    /// Windows default: `%ALLUSERSPROFILE%` (`%ProgramData%`, `%SystemDrive%\ProgramData`)
    ///   MacOS default: `/Library/Preferences`
    ///    *nix default: `/etc`
    ///   XDG directory: `XDG_CONFIG_DIRS` (first directory)
    global_configuration,
    /// The base directory relative to which user-specific data files should be written.
    ///
    /// Windows:       `%LOCALAPPDATA%\Temp`
    /// MacOS default: `$HOME/Library/Application Support`
    ///  *nix default: `$HOME/.local/share`
    /// XDG directory: `XDG_DATA_HOME`
    ///
    /// XDG's definition of `XDG_DATA_HOME`: There is a set of preference ordered base directories
    data,
    /// The base directory relative to which user-specific log files should be written.
    ///
    /// Windows:       `%LOCALAPPDATA%\Temp`
    /// MacOS default: `$HOME/Library/Logs`
    ///  *nix default: `$HOME/.local/state`
    /// XDG directory: `XDG_STATE_HOME`
    logs,
    /// The base directory relative to which user-specific runtime files and other file objects should be placed.
    ///
    /// Windows:       `%LOCALAPPDATA%\Temp`
    /// MacOS default: `$HOME/Library/Application Support`
    ///  *nix default: no default (only set with `XDG_RUNTIME_DIR`)
    /// XDG directory: `XDG_RUNTIME_DIR`
    ///
    runtime,
    /// Get the directory that contains the current executable.
    executable_dir,
};

// Explicitly define possible errors to make it clearer what callers need to handle
pub const Error = error{ ParseError, OutOfMemory };

pub const KnownFolderConfig = struct {
    xdg_force_default: bool = false,
    xdg_on_mac: bool = false,
};

/// Returns a directory handle, or, if the folder does not exist, `null`.
pub fn open(allocator: std.mem.Allocator, folder: KnownFolder, args: std.fs.Dir.OpenOptions) (std.fs.Dir.OpenError || Error)!?std.fs.Dir {
    const path = try getPath(allocator, folder) orelse return null;
    defer allocator.free(path);
    return try std.fs.cwd().openDir(path, args);
}

/// Returns the path to the folder or, if the folder does not exist, `null`.
pub fn getPath(allocator: std.mem.Allocator, folder: KnownFolder) Error!?[]const u8 {
    var system: DefaultSystem = .{};
    defer system.deinit();
    return getPathInner(DefaultSystem, &system, allocator, folder);
}

fn getPathInner(
    /// `DefaultDefaultSystem` or `TestingDefaultSystem`
    comptime System: type,
    system: *System,
    allocator: std.mem.Allocator,
    folder: KnownFolder,
) Error!?[]const u8 {
    if (folder == .executable_dir) {
        if (builtin.os.tag == .wasi) return null;
        return std.fs.selfExeDirPathAlloc(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }

    switch (builtin.os.tag) {
        .windows => {
            const funcs = struct {
                extern "shell32" fn SHGetKnownFolderPath(
                    rfid: *const std.os.windows.GUID,
                    dwFlags: std.os.windows.DWORD,
                    hToken: ?std.os.windows.HANDLE,
                    ppszPathL: *std.os.windows.PWSTR,
                ) callconv(.winapi) std.os.windows.HRESULT;
                extern "ole32" fn CoTaskMemFree(pv: std.os.windows.LPVOID) callconv(.winapi) void;
            };

            switch (getWindowsFolderSpec(folder)) {
                .by_guid => |guid| {
                    var dir_path_ptr: [*:0]u16 = undefined;
                    switch (funcs.SHGetKnownFolderPath(
                        &guid,
                        std.os.windows.KF_FLAG_CREATE, // TODO: Chose sane option here?
                        null,
                        &dir_path_ptr,
                    )) {
                        std.os.windows.S_OK => {
                            defer funcs.CoTaskMemFree(@ptrCast(dir_path_ptr));
                            const global_dir = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(dir_path_ptr)) catch |err| switch (err) {
                                error.UnexpectedSecondSurrogateHalf => return null,
                                error.ExpectedSecondSurrogateHalf => return null,
                                error.DanglingSurrogateHalf => return null,
                                error.OutOfMemory => return error.OutOfMemory,
                            };
                            return global_dir;
                        },
                        std.os.windows.E_OUTOFMEMORY => return error.OutOfMemory,
                        else => return null,
                    }
                },
                .by_env => |env_path| {
                    const env_var = std.process.getEnvVarOwned(allocator, env_path.env_var) catch |err| switch (err) {
                        error.EnvironmentVariableNotFound => return null,
                        error.InvalidWtf8 => return null,
                        error.OutOfMemory => |e| return e,
                    };

                    if (env_path.subdir) |sub_dir| {
                        defer allocator.free(env_var);
                        return try std.fs.path.join(allocator, &[_][]const u8{ env_var, sub_dir });
                    } else {
                        return env_var;
                    }
                },
            }
        },
        .macos => {
            if (system.config.xdg_on_mac) return try getPathXdg(System, system, allocator, folder);

            if (folder == .global_configuration) {
                // special case because the returned path is absolute
                return try allocator.dupe(u8, comptime getMacFolderSpec(.global_configuration));
            }

            const home_dir = try system.getenv(allocator, "HOME") orelse return null;

            if (folder == .home) {
                return try allocator.dupe(u8, home_dir);
            }

            const path = getMacFolderSpec(folder);
            return try std.fs.path.join(allocator, &.{ home_dir, path });
        },

        // Assume unix derivatives with XDG
        else => return try getPathXdg(System, system, allocator, folder),
    }
}

fn getPathXdg(
    /// `DefaultDefaultSystem` or `TestingDefaultSystem`
    comptime System: type,
    system: *System,
    allocator: std.mem.Allocator,
    folder: KnownFolder,
) Error!?[]const u8 {
    const folder_spec = getXdgFolderSpec(folder);

    fallback: {
        if (system.config.xdg_force_default and folder != .home)
            break :fallback;

        const env: []const u8, var env_owned: bool = env_opt: {
            if (try system.getenv(allocator, folder_spec.env.name)) |env_opt|
                break :env_opt .{ env_opt, false };

            if (system.config.xdg_force_default)
                break :fallback;

            if (!folder_spec.env.user_dir)
                break :fallback;

            const env = xdgUserDirLookup(System, system, allocator, folder_spec.env.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :fallback,
            } orelse break :fallback;

            break :env_opt .{ env, true };
        };
        defer if (env_owned) allocator.free(env);

        if (folder_spec.env.suffix) |suffix| {
            return try std.fs.path.join(allocator, &.{ env, suffix });
        }

        // XDG_CONFIG_DIRS is a sequence of directories that are separated with ':'
        if (folder == .global_configuration) {
            std.debug.assert(std.mem.eql(u8, folder_spec.env.name, "XDG_CONFIG_DIRS"));
            var iter = std.mem.splitScalar(u8, env, ':');
            return try allocator.dupe(u8, iter.first());
        }

        if (env_owned) {
            env_owned = false;
            return env;
        }

        return try allocator.dupe(u8, env);
    }

    const default = folder_spec.default orelse return null;
    if (default[0] == '~') {
        const home = try system.getenv(allocator, "HOME") orelse return null;
        return try std.fs.path.join(allocator, &.{ home, default[1..] });
    } else {
        return try allocator.dupe(u8, default);
    }
}

/// Encapsulates all operating system interactions
const DefaultSystem = struct {
    comptime config: KnownFolderConfig = if (@hasDecl(root, "known_folders_config")) root.known_folders_config else .{},
    envmap: if (builtin.os.tag == .wasi and !builtin.link_libc) ?std.process.EnvMap else ?void = null,

    pub fn deinit(system: *DefaultSystem) void {
        if (builtin.os.tag == .wasi and !builtin.link_libc) {
            if (system.envmap) |*envmap| envmap.deinit();
        }
    }

    /// Caller does **not** owns the returned memory.
    pub fn getenv(system: *DefaultSystem, allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!?[]const u8 {
        if (builtin.os.tag == .wasi and !builtin.link_libc) {
            if (system.envmap == null) {
                system.envmap = std.process.getEnvMap(allocator) catch return error.OutOfMemory;
            }
            return system.envmap.?.get(key);
        }
        return std.posix.getenv(key);
    }

    pub fn openFile(_: *DefaultSystem, dir_path: []const u8, sub_path: []const u8) std.fs.File.OpenError!std.fs.File {
        var dir = try std.fs.cwd().openDir(dir_path, .{});
        defer dir.close();
        return try dir.openFile(sub_path, .{});
    }
};

/// Encapsulates all operating system interactions which can be overriden for testing purposes.
const TestingSystem = struct {
    config: KnownFolderConfig,
    /// Specifies all accessible environment variables.
    ///
    /// Notable environment variables are `HOME`, `XDG_CONFIG_HOME` or `XDG_${FOLDER_NAME}_DIR`.
    env_map: []const struct { key: []const u8, value: ?[]const u8 } = &.{},
    /// Specifies all accessible files.
    ///
    /// This is only used for the `user-dirs.dirs` file but can easily be applied to any other file.
    files: []const struct { path: []const u8, data: ?[]const u8 } = &.{},

    tmp_dir: ?std.testing.TmpDir = null,

    comptime {
        std.debug.assert(builtin.os.tag != .windows);
    }

    pub fn deinit(impl: *TestingSystem) void {
        // TODO check which env variables and files have been accessed and fail the test if one was never used.
        if (impl.tmp_dir) |*tmp_dir| tmp_dir.cleanup();
    }

    /// Asserts that the environment variable is specified in `TestingSystem.env_map`.
    ///
    /// Caller does **not** owns the returned memory.
    pub fn getenv(system: *TestingSystem, allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!?[]const u8 {
        {
            // This allocation will simulate the possibility of allocation failure using `std.testing.checkAllAllocationFailures`
            allocator.free(try allocator.alloc(u8, 1));
        }

        for (system.env_map) |kv| {
            if (std.mem.eql(u8, key, kv.key)) return kv.value;
        }
        system.deinit();
        if (@hasDecl(std.zig, "fmtString")) {
            std.debug.panic("the result of `getenv(\"{f}\")` must explicitly specified in the TestingSystem", .{std.zig.fmtString(key)});
        } else {
            std.debug.panic("the result of `getenv(\"{}\")` must explicitly specified in the TestingSystem", .{std.zig.fmtEscapes(key)});
        }
    }

    /// Asserts that the file is specified in `TestingSystem.files`.
    pub fn openFile(system: *TestingSystem, dir_path: []const u8, sub_path: []const u8) std.fs.File.OpenError!std.fs.File {
        const file_path = std.fs.path.join(std.testing.allocator, &.{ dir_path, sub_path }) catch @panic("OOM");
        defer std.testing.allocator.free(file_path);

        const kv = for (system.files) |kv| {
            if (std.mem.eql(u8, file_path, kv.path)) break kv;
        } else {
            system.deinit();
            if (@hasDecl(std.zig, "fmtString")) {
                std.debug.panic("`openFile(\"{0f}\", \"{1f}\")` has been called on an unexpected file", .{ std.zig.fmtString(dir_path), std.zig.fmtString(sub_path) });
            } else {
                std.debug.panic("`openFile(\"{0}\", \"{1}\")` has been called on an unexpected file", .{ std.zig.fmtEscapes(dir_path), std.zig.fmtEscapes(sub_path) });
            }
        };

        const data = kv.data orelse return error.FileNotFound;

        const tmp_dir = if (system.tmp_dir) |*tmp_dir| tmp_dir else blk: {
            system.tmp_dir = std.testing.tmpDir(.{});
            break :blk &system.tmp_dir.?;
        };

        const buffer_size = std.base64.standard.Encoder.calcSize(kv.path.len);
        const buffer = std.testing.allocator.alloc(u8, buffer_size) catch @panic("OOM");
        defer std.testing.allocator.free(buffer);

        const prefix = std.base64.standard.Encoder.encode(buffer, kv.path);

        tmp_dir.dir.writeFile(.{
            .sub_path = prefix,
            .data = data,
        }) catch |err| {
            tmp_dir.cleanup();
            std.debug.panic("failed to create file './{s}/{s}' which represents '{s}': {}", .{ &tmp_dir.sub_path, prefix, kv.path, err });
        };

        return try tmp_dir.dir.openFile(prefix, .{});
    }
};

const UserDirLookupError =
    std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError;

const xdg_user_dir_lookup_line_buffer_size: usize = 511;

/// Looks up a XDG user directory of the specified type.
///
/// Caller owns the returned memory.
//
/// Ported of xdg-user-dir-lookup.c from xdg-user-dirs, which is licensed under the MIT license:
/// https://cgit.freedesktop.org/xdg/xdg-user-dirs/tree/xdg-user-dir-lookup.c
fn xdgUserDirLookup(
    /// `DefaultDefaultSystem` or `TestingDefaultSystem`
    comptime System: type,
    system: *System,
    allocator: std.mem.Allocator,
    /// A string that specifies the type of directory.
    ///
    /// Asserts that the folder type is should be one of the following:
    /// - `XDG_DESKTOP_DIR`
    /// - `XDG_DOWNLOAD_DIR`
    /// - `XDG_TEMPLATES_DIR`
    /// - `XDG_PUBLICSHARE_DIR`
    /// - `XDG_DOCUMENTS_DIR`
    /// - `XDG_MUSIC_DIR`
    /// - `XDG_PICTURES_DIR`
    /// - `XDG_VIDEOS_DIR`
    folder_type: []const u8,
) UserDirLookupError!?[]u8 {
    if (builtin.mode == .Debug) {
        std.debug.assert(std.mem.startsWith(u8, folder_type, "XDG_"));
        std.debug.assert(std.mem.endsWith(u8, folder_type, "_DIR"));

        const folder_name = folder_type["XDG_".len .. folder_type.len - "_DIR".len];
        std.debug.assert(std.mem.eql(u8, folder_name, "DESKTOP") or
            std.mem.eql(u8, folder_name, "DOWNLOAD") or
            std.mem.eql(u8, folder_name, "TEMPLATES") or
            std.mem.eql(u8, folder_name, "PUBLICSHARE") or
            std.mem.eql(u8, folder_name, "DOCUMENTS") or
            std.mem.eql(u8, folder_name, "MUSIC") or
            std.mem.eql(u8, folder_name, "PICTURES") or
            std.mem.eql(u8, folder_name, "VIDEOS"));
    }

    const home_dir: []const u8 = try system.getenv(allocator, "HOME") orelse return null;
    const maybe_config_home: ?[]const u8 = if (try system.getenv(allocator, "XDG_CONFIG_HOME")) |value|
        if (value.len != 0) value else null
    else
        null;

    const file: std.fs.File = if (maybe_config_home) |config_home|
        try system.openFile(config_home, "user-dirs.dirs")
    else
        try system.openFile(home_dir, ".config/user-dirs.dirs");
    defer file.close();

    var buffer: [xdg_user_dir_lookup_line_buffer_size + 1]u8 = undefined;
    var line_it: if (@hasDecl(std.fs.File, "stdin")) LineIterator else OldLineIterator = .init(file);

    var user_dir: ?[]u8 = null;
    while (try line_it.next(&buffer)) |line_capture| {
        var line = line_capture;

        while (line[0] == ' ' or line[0] == '\t')
            line = line[1..];

        if (!std.mem.startsWith(u8, line, folder_type))
            continue;
        line = line[folder_type.len..];

        while (line[0] == ' ' or line[0] == '\t') line = line[1..];

        if (line[0] != '=')
            continue;
        line = line["=".len..];

        while (line[0] == ' ' or line[0] == '\t') line = line[1..];

        if (line[0] != '\"')
            continue;
        line = line["\"".len..];

        if (user_dir) |path| {
            allocator.free(path);
            user_dir = null;
        }

        var is_relative = false;
        if (std.mem.startsWith(u8, line, "$HOME/")) {
            line = line["$HOME/".len..];
            is_relative = true;
        } else if (line[0] != '/') {
            continue;
        }

        var escaped_character_count: usize = 0;

        var index: usize = 0;
        const end_index: usize = while (index < line.len) : (index += 1) {
            if (line[index] == '\"')
                break index;
            if (line[index] == '\\' and line[index + 1] != 0) {
                // escaped character
                escaped_character_count += 1;
                index += 1;
            }
        } else line.len;

        const new_user_dir_len = (if (is_relative) home_dir.len + "/".len else 0) + end_index - escaped_character_count;
        const new_user_dir = try allocator.alloc(u8, new_user_dir_len);
        errdefer @compileError("");

        var out_index: usize = 0;
        if (is_relative) {
            @memcpy(new_user_dir[0..home_dir.len], home_dir);
            new_user_dir[home_dir.len] = '/';
            out_index = home_dir.len + 1;
        }

        index = 0;
        while (index < end_index) : (index += 1) {
            const ch1 = line[index];
            const ch2 = line[index + 1];
            if (ch1 == '\\' and ch2 != 0) {
                // escaped character
                new_user_dir[out_index] = ch2;
                out_index += 1;
                index += 1;
            } else {
                new_user_dir[out_index] = ch1;
                out_index += 1;
            }
        }

        std.debug.assert(out_index == new_user_dir.len);
        std.debug.assert(user_dir == null);
        user_dir = new_user_dir;
    }

    return user_dir;
}

const OldLineIterator = struct {
    fbr: std.io.BufferedReader(4096, std.fs.File.Reader),

    fn init(file: std.fs.File) OldLineIterator {
        return .{
            .fbr = std.io.bufferedReader(file.reader()),
        };
    }

    fn next(it: *OldLineIterator, buffer: []u8) std.posix.ReadError!?[:0]const u8 {
        const reader = it.fbr.reader();

        // Similar to `readUntilDelimiterOrEof` but also writes a null-terminator
        for (buffer, 0..) |*out, index| {
            const byte = reader.readByte() catch |err| switch (err) {
                error.EndOfStream => if (index == 0) return null else '\n',
                else => |e| return e,
            };
            if (byte == '\n') {
                out.* = 0;
                return buffer[0..index :0];
            }
            out.* = byte;
        } else {
            // This happens when the line is longer than 511 characters
            // There are four possible ways to handle this:
            //  - use dynamic allocation to acquire enough storage
            //  - return an error
            //  - skip the line
            //  - truncate the line
            //
            // The xdg-user-dir implementation chooses to trunacte the line.
            // See "getPath - user-dirs.dirs - very long line" test

            try reader.skipUntilDelimiterOrEof('\n');

            buffer[buffer.len - 1] = 0;
            return buffer[0 .. buffer.len - 1 :0];
        }
    }
};

const LineIterator = struct {
    file_reader: std.fs.File.Reader,
    keep_reading: bool,
    discard_until_newline: bool,

    fn init(file: std.fs.File) LineIterator {
        return .{
            .file_reader = file.reader(undefined),
            .keep_reading = true,
            .discard_until_newline = false,
        };
    }

    fn next(it: *LineIterator, buffer: []u8) std.posix.ReadError!?[:'\n']const u8 {
        if (!it.keep_reading) return null;

        const reader = &it.file_reader.interface;
        reader.buffer = buffer[0 .. buffer.len - 1]; // leave space for the sentinel

        if (it.discard_until_newline) {
            it.discard_until_newline = false;
            _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                error.ReadFailed => return it.file_reader.err.?,
                error.EndOfStream => return null,
            };
        }

        return reader.takeSentinel('\n') catch |err| switch (err) {
            error.ReadFailed => return it.file_reader.err.?,
            error.EndOfStream => {
                if (reader.bufferedLen() == 0)
                    return null; // trailing newline

                // This is the last line
                buffer[reader.end] = '\n';
                const line = buffer[reader.seek..reader.end :'\n'];
                it.keep_reading = false;
                return line;
            },
            error.StreamTooLong => {
                // This happens when the line is longer than 511 characters
                // There are four possible ways to handle this:
                //  - use dynamic allocation to acquire enough storage
                //  - return an error
                //  - skip the line
                //  - truncate the line
                //
                // The xdg-user-dir implementation chooses to trunacte the line.
                // See "getPath - user-dirs.dirs - very long line" test

                buffer[reader.end] = '\n';
                const line = buffer[reader.seek..reader.end :'\n'];
                it.discard_until_newline = true;

                return line;
            },
        };
    }
};

/// Contains the GUIDs for each available known-folder on windows
const WindowsFolderSpec = union(enum) {
    by_guid: std.os.windows.GUID,
    by_env: struct {
        env_var: []const u8,
        subdir: ?[]const u8,
    },
};

fn getWindowsFolderSpec(folder: KnownFolder) WindowsFolderSpec {
    return switch (folder) {
        .executable_dir => unreachable,
        .home => .{ .by_guid = comptime std.os.windows.GUID.parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}") }, // FOLDERID_Profile
        .documents => .{ .by_guid = comptime std.os.windows.GUID.parse("{FDD39AD0-238F-46AF-ADB4-6C85480369C7}") }, // FOLDERID_Documents
        .pictures => .{ .by_guid = comptime std.os.windows.GUID.parse("{33E28130-4E1E-4676-835A-98395C3BC3BB}") }, // FOLDERID_Pictures
        .music => .{ .by_guid = comptime std.os.windows.GUID.parse("{4BD8D571-6D19-48D3-BE97-422220080E43}") }, // FOLDERID_Music
        .videos => .{ .by_guid = comptime std.os.windows.GUID.parse("{18989B1D-99B5-455B-841C-AB7C74E4DDFC}") }, // FOLDERID_Videos
        .desktop => .{ .by_guid = comptime std.os.windows.GUID.parse("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}") }, // FOLDERID_Desktop
        .downloads => .{ .by_guid = comptime std.os.windows.GUID.parse("{374DE290-123F-4565-9164-39C4925E467B}") }, // FOLDERID_Downloads
        .public => .{ .by_guid = comptime std.os.windows.GUID.parse("{DFDF76A2-C82A-4D63-906A-5644AC457385}") }, // FOLDERID_Public
        .fonts => .{ .by_guid = comptime std.os.windows.GUID.parse("{FD228CB7-AE11-4AE3-864C-16F3910AB8FE}") }, // FOLDERID_Fonts
        .app_menu => .{ .by_guid = comptime std.os.windows.GUID.parse("{625B53C3-AB48-4EC1-BA1F-A1EF4146FC19}") }, // FOLDERID_StartMenu
        .cache => .{ .by_env = .{ .env_var = "LOCALAPPDATA", .subdir = "Temp" } }, // %LOCALAPPDATA%\Temp
        .roaming_configuration => .{ .by_guid = comptime std.os.windows.GUID.parse("{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}") }, // FOLDERID_RoamingAppData
        .local_configuration => .{ .by_guid = comptime std.os.windows.GUID.parse("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}") }, // FOLDERID_LocalAppData
        .global_configuration => .{ .by_guid = comptime std.os.windows.GUID.parse("{62AB5D82-FDC1-4DC3-A9DD-070D1D495D97}") }, // FOLDERID_ProgramData
        .data => .{ .by_env = .{ .env_var = "APPDATA", .subdir = null } }, // %LOCALAPPDATA%\Temp
        .logs => .{ .by_env = .{ .env_var = "LOCALAPPDATA", .subdir = "Temp" } }, // %LOCALAPPDATA%\Temp
        .runtime => .{ .by_env = .{ .env_var = "LOCALAPPDATA", .subdir = "Temp" } },
    };
}

/// The default value for `KnownFolder.global_configuration` is the only absolute path. All others default values are relative to the home directory.
fn getMacFolderSpec(folder: KnownFolder) []const u8 {
    return switch (folder) {
        .executable_dir => unreachable,
        .home => unreachable,
        .documents => "Documents",
        .pictures => "Pictures",
        .music => "Music",
        .videos => "Movies",
        .desktop => "Desktop",
        .downloads => "Downloads",
        .public => "Public",
        .fonts => "Library/Fonts",
        .app_menu => "Applications",
        .cache => "Library/Caches",
        .roaming_configuration => "Library/Preferences",
        .local_configuration => "Library/Application Support",
        .global_configuration => "/Library/Preferences", // absolute path
        .data => "Library/Application Support",
        .logs => "Library/Logs",
        .runtime => "Library/Application Support",
    };
}

/// Contains the xdg environment variable and the default value for each available known-folder
const XdgFolderSpec = struct {
    env: struct {
        /// Name of the environment variable.
        name: []const u8,
        /// `true` means that the folder is a user directory that can be overriden in the `user-dirs.dirs`. See `xdgUserDirLookup`.
        /// `false` means that the folder is system directory.
        user_dir: bool,
        suffix: ?[]const u8,
    },
    default: ?[]const u8,
};

/// The default value for `KnownFolder.global_configuration` is the only absolute path. All others default values are relative to the home directory.
fn getXdgFolderSpec(folder: KnownFolder) XdgFolderSpec {
    return switch (folder) {
        .executable_dir => unreachable,
        .home => .{ .env = .{ .name = "HOME", .user_dir = false, .suffix = null }, .default = null },
        .documents => .{ .env = .{ .name = "XDG_DOCUMENTS_DIR", .user_dir = true, .suffix = null }, .default = "~/Documents" },
        .pictures => .{ .env = .{ .name = "XDG_PICTURES_DIR", .user_dir = true, .suffix = null }, .default = "~/Pictures" },
        .music => .{ .env = .{ .name = "XDG_MUSIC_DIR", .user_dir = true, .suffix = null }, .default = "~/Music" },
        .videos => .{ .env = .{ .name = "XDG_VIDEOS_DIR", .user_dir = true, .suffix = null }, .default = "~/Videos" },
        .desktop => .{ .env = .{ .name = "XDG_DESKTOP_DIR", .user_dir = true, .suffix = null }, .default = "~/Desktop" },
        .downloads => .{ .env = .{ .name = "XDG_DOWNLOAD_DIR", .user_dir = true, .suffix = null }, .default = "~/Downloads" },
        .public => .{ .env = .{ .name = "XDG_PUBLICSHARE_DIR", .user_dir = true, .suffix = null }, .default = "~/Public" },
        .fonts => .{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = "/fonts" }, .default = "~/.local/share/fonts" },
        .app_menu => .{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = "/applications" }, .default = "~/.local/share/applications" },
        .cache => .{ .env = .{ .name = "XDG_CACHE_HOME", .user_dir = false, .suffix = null }, .default = "~/.cache" },
        .roaming_configuration => .{ .env = .{ .name = "XDG_CONFIG_HOME", .user_dir = false, .suffix = null }, .default = "~/.config" },
        .local_configuration => .{ .env = .{ .name = "XDG_CONFIG_HOME", .user_dir = false, .suffix = null }, .default = "~/.config" },
        .global_configuration => .{ .env = .{ .name = "XDG_CONFIG_DIRS", .user_dir = false, .suffix = null }, .default = "/etc" }, // absolute path
        .data => .{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = null }, .default = "~/.local/share" },
        .logs => .{ .env = .{ .name = "XDG_STATE_HOME", .user_dir = false, .suffix = null }, .default = "~/.local/state" },
        .runtime => .{ .env = .{ .name = "XDG_RUNTIME_DIR", .user_dir = false, .suffix = null }, .default = null },
    };
}

const GetPathTestParams = struct {
    system: TestingSystem,
    folder: KnownFolder,
    expected: ?[]const u8,
};

fn testGetPath(get_path_params: GetPathTestParams) !void {
    const funcs = struct {
        fn testFunc(allocator: std.mem.Allocator, params: GetPathTestParams) !void {
            var system = params.system;
            defer system.deinit();

            const actual = try getPathInner(TestingSystem, &system, allocator, params.folder);
            defer if (actual) |path| allocator.free(path);

            if (params.expected == null and actual == null) return;
            if (params.expected != null and actual != null and std.mem.eql(u8, params.expected.?, actual.?)) return;
            std.debug.print("expected: '{?s}' but got '{?s}'\n", .{ params.expected, actual });
            return error.TestExpectedEqual;
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, funcs.testFunc, .{get_path_params});
}

test "getPath - no HOME" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = null },

            .{ .key = "XDG_DESKTOP_DIR", .value = "/home/janedoe/Desktop" },
            .{ .key = "XDG_DOWNLOAD_DIR", .value = null },
        },
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .home,
        .expected = null,
    });

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/home/janedoe/Desktop",
    });

    try testGetPath(.{
        .system = system,
        .folder = .downloads,
        .expected = null,
    });
}

test "getPath - find HOME without accessing XDG_CONFIG_HOME" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
        },
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .home,
        .expected = "/home/janedoe",
    });
}

test "getPath - no user-dirs.dirs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = null },

            .{ .key = "XDG_DESKTOP_DIR", .value = null },
            .{ .key = "XDG_DOWNLOAD_DIR", .value = "/mnt/drive/downloads" },
            .{ .key = "XDG_DATA_HOME", .value = null },
        },
        .files = &.{.{ .path = "/home/janedoe/.config/user-dirs.dirs", .data = null }},
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .home,
        .expected = "/home/janedoe",
    });

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/home/janedoe/Desktop",
    });

    try testGetPath(.{
        .system = system,
        .folder = .downloads,
        .expected = "/mnt/drive/downloads",
    });

    try testGetPath(.{
        .system = system,
        .folder = .data,
        .expected = "/home/janedoe/.local/share",
    });

    try testGetPath(.{
        .system = system,
        .folder = .fonts,
        .expected = "/home/janedoe/.local/share/fonts",
    });
}

test "getPath - XDG_DATA_HOME with suffix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = null },

            .{ .key = "XDG_DATA_HOME", .value = "/mnt/data" },
        },
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .fonts,
        .expected = "/mnt/data/fonts",
    });

    try testGetPath(.{
        .system = system,
        .folder = .app_menu,
        .expected = "/mnt/data/applications",
    });
}

test "getPath - user-dirs.dirs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = null },

            .{ .key = "XDG_DESKTOP_DIR", .value = null },
            .{ .key = "XDG_DOWNLOAD_DIR", .value = null },
            .{ .key = "XDG_DOCUMENTS_DIR", .value = null },
        },
        .files = &.{.{
            .path = "/home/janedoe/.config/user-dirs.dirs",
            .data =
            \\
            \\# M for Mini
            \\W for Wumbo
            \\
            \\XDG_DESKTOP_DIR="/mnt/home/Desktop"
            \\  XDG_DOCUMENTS_DIR = "$HOME/xdg/Documents"
            ,
        }},
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/mnt/home/Desktop",
    });

    try testGetPath(.{
        .system = system,
        .folder = .downloads,
        .expected = "/home/janedoe/Downloads",
    });

    try testGetPath(.{
        .system = system,
        .folder = .documents,
        .expected = "/home/janedoe/xdg/Documents",
    });
}

test "getPath - user-dirs.dirs - XDG_CONFIG_HOME" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = "/home/janedoe/custom" },

            .{ .key = "XDG_DESKTOP_DIR", .value = null },
        },
        .files = &.{.{
            .path = "/home/janedoe/custom/user-dirs.dirs",
            .data =
            \\XDG_DESKTOP_DIR="/mnt/Desktop"
            ,
        }},
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/mnt/Desktop",
    });
}

test "getPath - user-dirs.dirs - duplicate config" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = null },

            .{ .key = "XDG_DESKTOP_DIR", .value = null },
        },
        .files = &.{.{
            .path = "/home/janedoe/.config/user-dirs.dirs",
            .data =
            \\XDG_DESKTOP_DIR="/mnt/first/Desktop"
            \\XDG_DESKTOP_DIR="/mnt/second/Desktop"
            ,
        }},
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/mnt/second/Desktop",
    });
}

test "getPath - user-dirs.dirs - trailing newline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = "/home/janedoe/custom" },

            .{ .key = "XDG_VIDEOS_DIR", .value = null },
        },
        .files = &.{.{
            .path = "/home/janedoe/custom/user-dirs.dirs",
            .data =
            \\XDG_VIDEOS_DIR="/mnt/Videos"
            \\
            ,
        }},
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .videos,
        .expected = "/mnt/Videos",
    });
}

test "getPath - user-dirs.dirs - escaped path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = null },

            .{ .key = "XDG_DESKTOP_DIR", .value = null },
            .{ .key = "XDG_DOWNLOAD_DIR", .value = null },
        },
        .files = &.{.{
            .path = "/home/janedoe/.config/user-dirs.dirs",
            .data =
            \\XDG_DESKTOP_DIR="/mnt/\\/Desktop"
            \\XDG_DOWNLOAD_DIR="/mnt/\ /Desktop"
            ,
        }},
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/mnt/\\/Desktop",
    });

    try testGetPath(.{
        .system = system,
        .folder = .downloads,
        .expected = "/mnt/ /Desktop",
    });
}

test "getPath - user-dirs.dirs - very long line" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const len = "XDG_DESKTOP_DIR  =\"\"".len;
    const xdg_dir_desktop = "/" ++ "a" ** (xdg_user_dir_lookup_line_buffer_size - len - 1);
    const xdg_dir_download = "/" ++ "b" ** (xdg_user_dir_lookup_line_buffer_size - len);
    const xdg_dir_documents = "/" ++ "c" ** (xdg_user_dir_lookup_line_buffer_size - len + 1);
    const xdg_dir_documents_truncated = "/" ++ "c" ** (xdg_user_dir_lookup_line_buffer_size - len);

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = null },

            .{ .key = "XDG_DESKTOP_DIR", .value = null },
            .{ .key = "XDG_DOWNLOAD_DIR", .value = null },
            .{ .key = "XDG_DOCUMENTS_DIR", .value = null },
            .{ .key = "XDG_MUSIC_DIR", .value = null },
        },
        .files = &.{.{
            .path = "/home/janedoe/.config/user-dirs.dirs",
            .data = std.fmt.comptimePrint(
                \\XDG_DESKTOP_DIR  ="{s}"
                \\XDG_DOWNLOAD_DIR ="{s}"
                \\XDG_DOCUMENTS_DIR="{s}"
                \\XDG_MUSIC_DIR="$HOME/music"
            , .{ xdg_dir_desktop, xdg_dir_download, xdg_dir_documents }),
        }},
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = xdg_dir_desktop,
    });

    try testGetPath(.{
        .system = system,
        .folder = .downloads,
        .expected = xdg_dir_download,
    });

    try testGetPath(.{
        .system = system,
        .folder = .documents,
        .expected = xdg_dir_documents_truncated,
    });

    try testGetPath(.{
        .system = system,
        .folder = .music,
        .expected = "/home/janedoe/music",
    });
}

test "getPath - user-dirs.dirs - invalid path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
            .{ .key = "XDG_CONFIG_HOME", .value = null },

            .{ .key = "XDG_DESKTOP_DIR", .value = null },
        },
        .files = &.{.{
            .path = "/home/janedoe/.config/user-dirs.dirs",
            .data =
            \\XDG_DESKTOP_DIR="non/absolute/path"
            ,
        }},
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/home/janedoe/Desktop", // fallback
    });
}

test "getPath - .global_configuration" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "XDG_CONFIG_DIRS", .value = null },
        },
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .global_configuration,
        .expected = "/etc",
    });
}

test "getPath - .global_configuration with XDG_CONFIG_DIRS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true },
        .env_map = &.{
            .{ .key = "XDG_CONFIG_DIRS", .value = "/mnt/etc" },
        },
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .global_configuration,
        .expected = "/mnt/etc",
    });

    system.env_map = &.{
        .{ .key = "XDG_CONFIG_DIRS", .value = "/mnt/first:/mnt/second" },
    };
    try testGetPath(.{
        .system = system,
        .folder = .global_configuration,
        .expected = "/mnt/first",
    });
}

test "getPath - with xdg_force_default=true" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = true, .xdg_force_default = true },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },

            // The fact that the following line wasn't necessary proves that "XDG_DESKTOP_DIR" was never accessed.
            // .{ .key = "XDG_DESKTOP_DIR", .value = null },
        },
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .home,
        .expected = "/home/janedoe",
    });

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/home/janedoe/Desktop",
    });

    try testGetPath(.{
        .system = system,
        .folder = .global_configuration,
        .expected = "/etc",
    });
}

test "getPath - with xdg_on_mac=false" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = false },
        .env_map = &.{
            .{ .key = "HOME", .value = "/home/janedoe" },
        },
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .desktop,
        .expected = "/home/janedoe/Desktop",
    });

    try testGetPath(.{
        .system = system,
        .folder = .fonts,
        .expected = "/home/janedoe/Library/Fonts",
    });

    try testGetPath(.{
        .system = system,
        .folder = .videos,
        .expected = "/home/janedoe/Movies",
    });
}

test "getPath - .global_configuration with xdg_on_mac=false" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;

    var system: TestingSystem = .{
        .config = .{ .xdg_on_mac = false },
        .env_map = &.{
            // The fact that the following line wasn't necessary proves that "HOME" was never accessed.
            // .{ .key = "HOME", .value = "/home/janedoe" },
        },
    };
    defer system.deinit();

    try testGetPath(.{
        .system = system,
        .folder = .global_configuration,
        .expected = "/Library/Preferences",
    });
}

test "query each known folders" {
    for (std.meta.tags(KnownFolder)) |folder| {
        const path_or_null = try getPath(std.testing.allocator, folder);
        defer if (path_or_null) |path| std.testing.allocator.free(path);
        std.debug.print("{s} => {?s}\n", .{ @tagName(folder), path_or_null });
    }
}

test "open each known folders" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    for (std.meta.tags(KnownFolder)) |folder| {
        var dir_or_null = open(std.testing.allocator, folder, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        if (dir_or_null) |*dir| {
            dir.close();
        }
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
