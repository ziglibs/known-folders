const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

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
    runtime,
    executable_dir,
};

// Explicitly define possible errors to make it clearer what callers need to handle
pub const Error = error{ ParseError, OutOfMemory };

pub const KnownFolderConfig = struct {
    xdg_force_default: bool = false,
    xdg_on_mac: bool = false,
};

const OpenOptions = if (@import("builtin").zig_version.order(std.SemanticVersion.parse("0.14.0-dev.211+0cc42d090") catch unreachable) == .lt)
    std.fs.Dir.OpenDirOptions
else
    std.fs.Dir.OpenOptions;

/// Returns a directory handle, or, if the folder does not exist, `null`.
pub fn open(allocator: std.mem.Allocator, folder: KnownFolder, args: OpenOptions) (std.fs.Dir.OpenError || Error)!?std.fs.Dir {
    const path = try getPath(allocator, folder) orelse return null;
    defer allocator.free(path);
    return try std.fs.cwd().openDir(path, args);
}

/// Returns the path to the folder or, if the folder does not exist, `null`.
pub fn getPath(allocator: std.mem.Allocator, folder: KnownFolder) Error!?[]const u8 {
    if (folder == .executable_dir) {
        if (builtin.os.tag == .wasi) return null;
        return std.fs.selfExeDirPathAlloc(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }

    // used for temporary allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    switch (builtin.os.tag) {
        .windows => {
            const funcs = struct {
                extern "shell32" fn SHGetKnownFolderPath(
                    rfid: *const std.os.windows.GUID,
                    dwFlags: std.os.windows.DWORD,
                    hToken: ?std.os.windows.HANDLE,
                    ppszPathL: *std.os.windows.PWSTR,
                ) callconv(std.os.windows.WINAPI) std.os.windows.HRESULT;
                extern "ole32" fn CoTaskMemFree(pv: std.os.windows.LPVOID) callconv(std.os.windows.WINAPI) void;
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
                    if (env_path.subdir) |sub_dir| {
                        const root_path = std.process.getEnvVarOwned(arena.allocator(), env_path.env_var) catch |err| switch (err) {
                            error.EnvironmentVariableNotFound => return null,
                            error.InvalidWtf8 => return null,
                            error.OutOfMemory => |e| return e,
                        };
                        return try std.fs.path.join(allocator, &[_][]const u8{ root_path, sub_dir });
                    } else {
                        return std.process.getEnvVarOwned(allocator, env_path.env_var) catch |err| switch (err) {
                            error.EnvironmentVariableNotFound => return null,
                            error.InvalidWtf8 => return null,
                            error.OutOfMemory => |e| return e,
                        };
                    }
                },
            }
        },
        .macos => {
            if (@hasDecl(root, "known_folders_config") and root.known_folders_config.xdg_on_mac) {
                return getPathXdg(allocator, &arena, folder);
            }

            if (folder == .global_configuration) {
                // special case because the returned path is absolute
                return try allocator.dupe(u8, comptime getMacFolderSpec(.global_configuration));
            }

            const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch null orelse return null;
            defer allocator.free(home_dir);

            if (folder == .home) {
                return home_dir;
            }

            const path = getMacFolderSpec(folder);
            return try std.fs.path.join(allocator, &.{ home_dir, path });
        },

        // Assume unix derivatives with XDG
        else => {
            return getPathXdg(allocator, &arena, folder);
        },
    }
    unreachable;
}

fn getPathXdg(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, folder: KnownFolder) Error!?[]const u8 {
    const folder_spec = getXdgFolderSpec(folder);

    if (@hasDecl(root, "known_folders_config") and root.known_folders_config.xdg_force_default) {
        if (folder_spec.default) |default| {
            if (default[0] == '~') {
                const home = std.process.getEnvVarOwned(arena.allocator(), "HOME") catch null orelse return null;
                return try std.mem.concat(allocator, u8, &[_][]const u8{ home, default[1..] });
            } else {
                return try allocator.dupe(u8, default);
            }
        }
    }

    const env_opt = env_opt: {
        if (std.process.getEnvVarOwned(arena.allocator(), folder_spec.env.name) catch null) |env_opt| break :env_opt env_opt;

        if (!folder_spec.env.user_dir) break :env_opt null;

        // TODO: add caching so we only need to read once in a run
        const config_dir_path = getPathXdg(arena.allocator(), arena, .local_configuration) catch null orelse break :env_opt null;
        const config_dir = std.fs.cwd().openDir(config_dir_path, .{}) catch break :env_opt null;
        const home = std.process.getEnvVarOwned(arena.allocator(), "HOME") catch null orelse break :env_opt null;
        const user_dirs = config_dir.openFile("user-dirs.dirs", .{}) catch null orelse break :env_opt null;

        var read: [1024 * 8]u8 = undefined;
        _ = user_dirs.readAll(&read) catch null orelse break :env_opt null;
        const start = folder_spec.env.name.len + "=\"$HOME".len;

        var line_it = std.mem.splitScalar(u8, &read, '\n');
        while (line_it.next()) |line| {
            if (std.mem.startsWith(u8, line, folder_spec.env.name)) {
                const end = line.len - 1;
                if (start >= end) {
                    return error.ParseError;
                }

                const subdir = line[start..end];

                break :env_opt try std.mem.concat(arena.allocator(), u8, &[_][]const u8{ home, subdir });
            }
        }
        break :env_opt null;
    };

    if (env_opt) |env| {
        if (folder_spec.env.suffix) |suffix| {
            return try std.mem.concat(allocator, u8, &[_][]const u8{ env, suffix });
        } else {
            if (std.mem.eql(u8, folder_spec.env.name, "XDG_CONFIG_DIRS")) {
                var iter = std.mem.splitScalar(u8, env, ':');
                return try allocator.dupe(u8, iter.next() orelse "");
            } else {
                return try allocator.dupe(u8, env);
            }
        }
    } else {
        const default = folder_spec.default orelse return null;
        if (default[0] == '~') {
            const home = std.process.getEnvVarOwned(arena.allocator(), "HOME") catch null orelse return null;
            return try std.mem.concat(allocator, u8, &[_][]const u8{ home, default[1..] });
        } else {
            return try allocator.dupe(u8, default);
        }
    }
}

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
        .runtime => .{ .env = .{ .name = "XDG_RUNTIME_DIR", .user_dir = false, .suffix = null }, .default = null },
    };
}

// Ref decls
comptime {
    _ = KnownFolder;
    _ = Error;
    _ = open;
    _ = getPath;
}

test "query each known folders" {
    inline for (std.meta.fields(KnownFolder)) |fld| {
        const path_or_null = try getPath(std.testing.allocator, @field(KnownFolder, fld.name));
        if (path_or_null) |path| {
            // TODO: Remove later
            std.debug.print("{s} => '{s}'\n", .{ fld.name, path });
            std.testing.allocator.free(path);
        }
    }
}

test "open each known folders" {
    inline for (std.meta.fields(KnownFolder)) |fld| {
        var dir_or_null = open(std.testing.allocator, @field(KnownFolder, fld.name), .{ .access_sub_paths = true }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        if (dir_or_null) |*dir| {
            dir.close();
        }
    }
}
