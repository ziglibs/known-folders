const std = @import("std");

pub const KnownFolder = enum {
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
    runtime,
};

// Explicitly define possible errors to make it clearer what callers need to handle
// TODO: fill this in
pub const Error = error{OutOfMemory};

/// Returns a directory handle, or, if the folder does not exist, `null`.
pub fn open(allocator: *std.mem.Allocator, folder: KnownFolder, args: std.fs.Dir.OpenDirOptions) (std.fs.Dir.OpenError || Error)!?std.fs.Dir {
    var path_or_null = try getPath(allocator, folder);
    if (path_or_null) |path| {
        defer allocator.free(path);

        return try std.fs.cwd().openDir(path, args);
    } else {
        return null;
    }
}

/// Returns the path to the folder or, if the folder does not exist, `null`.
pub fn getPath(allocator: *std.mem.Allocator, folder: KnownFolder) Error!?[]const u8 {

    // used for temporary allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    switch (std.builtin.os.tag) {
        .windows => {
            const folder_spec = windows_folder_spec.get(folder);

            switch (folder_spec) {
                .by_guid => |guid| {
                    var dir_path_ptr: [*:0]u16 = undefined;
                    switch (std.os.windows.shell32.SHGetKnownFolderPath(
                        &guid,
                        std.os.windows.KF_FLAG_CREATE, // TODO: Chose sane option here?
                        null,
                        &dir_path_ptr,
                    )) {
                        std.os.windows.S_OK => {
                            defer std.os.windows.ole32.CoTaskMemFree(@ptrCast(*c_void, dir_path_ptr));
                            const global_dir = std.unicode.utf16leToUtf8Alloc(allocator, std.mem.spanZ(dir_path_ptr)) catch |err| switch (err) {
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
                        const root_path = std.process.getEnvVarOwned(&arena.allocator, env_path.env_var) catch |err| switch (err) {
                            error.EnvironmentVariableNotFound => return null,
                            error.InvalidUtf8 => return null,
                            error.OutOfMemory => |e| return e,
                        };
                        return try std.fs.path.join(allocator, &[_][]const u8{ root_path, sub_dir });
                    } else {
                        return std.process.getEnvVarOwned(allocator, env_path.env_var) catch |err| switch (err) {
                            error.EnvironmentVariableNotFound => return null,
                            error.InvalidUtf8 => return null,
                            error.OutOfMemory => |e| return e,
                        };
                    }
                },
            }
        },
        .macosx => {
            // TODO: Implement
            @panic("not implemented yet");
        },

        // Assume unix derivatives with XDG
        else => {
            const folder_spec = xdg_folder_spec.get(folder);

            var env_opt = std.os.getenv(folder_spec.env.name);

            if (env_opt == null and folder_spec.env.user_dir) {
                // TODO: add caching so we only need to read once in a run
                // TODO: maybe parse this in a saner way?
                if (open(&arena.allocator, .local_configuration, .{}) catch null) |config_dir| {
                    if (std.os.getenv("HOME")) |home| {
                        if (config_dir.openFile("user-dirs.dirs", .{}) catch null) |user_dirs| {
                            var read: [1024 * 8]u8 = undefined;
                            if (user_dirs.inStream().readAll(&read) catch null) |_| {
                                var line_it = std.mem.split(&read, "\n");
                                while (line_it.next()) |line| {
                                    if (std.mem.startsWith(u8, line, folder_spec.env.name)) {
                                        var split = std.mem.split(line, "=");
                                        _ = split.next();

                                        // "$HOME/123" -> /123
                                        const rest = split.rest();
                                        var subdir = rest[6 .. rest.len - 1];
                                        env_opt = std.mem.concat(&arena.allocator, u8, &[_][]const u8{ home, subdir }) catch null;
                                    }
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            if (env_opt) |env| {
                if (folder_spec.env.suffix) |suffix| {
                    return try std.mem.concat(allocator, u8, &[_][]const u8{ env, suffix });
                } else {
                    // TODO: this allocation is not necessary but else this cannot be freed by the allocator
                    return try std.mem.dupe(allocator, u8, env);
                }
            } else if (folder_spec.default) |default| {
                if (std.os.getenv("HOME")) |home| {
                    return try std.mem.concat(allocator, u8, &[_][]const u8{ home, default });
                } else {
                    return null;
                }
            } else {
                return null;
            }
        },
    }
    unreachable;
}

/// Contains the GUIDs for each available known-folder on windows
const WindowsFolderSpec = union(enum) {
    by_guid: std.os.windows.GUID,
    by_env: struct {
        env_var: []const u8,
        subdir: ?[]const u8,
    },
};

/// Contains the xdg environment variable amd the default value for each available known-folder on windows
const XdgFolderSpec = struct {
    env: struct {
        name: []const u8,
        user_dir: bool,
        suffix: ?[]const u8,
    },
    default: ?[]const u8,
};

/// This returns a struct type with one field per KnownFolder of type `T`.
/// used for storing different config data per field
fn KnownFolderConfig(comptime T: type) type {
    return struct {
        const Self = @This();

        home: T,
        documents: T,
        pictures: T,
        music: T,
        videos: T,
        templates: T,
        desktop: T,
        downloads: T,
        public: T,
        fonts: T,
        app_menu: T,
        cache: T,
        roaming_configuration: T,
        local_configuration: T,
        data: T,
        runtime: T,

        fn get(self: Self, folder: KnownFolder) T {
            inline for (std.meta.fields(Self)) |fld| {
                if (folder == @field(KnownFolder, fld.name))
                    return @field(self, fld.name);
            }
            unreachable;
        }
    };
}

/// Stores how to find each known folder on windows.
const windows_folder_spec = comptime blk: {
    // workaround for zig eval branch quota when parsing the GUIDs
    @setEvalBranchQuota(10_000);
    break :blk KnownFolderConfig(WindowsFolderSpec){
        .home = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}") }, // FOLDERID_Profile
        .documents = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{FDD39AD0-238F-46AF-ADB4-6C85480369C7}") }, // FOLDERID_Documents
        .pictures = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{33E28130-4E1E-4676-835A-98395C3BC3BB}") }, // FOLDERID_Pictures
        .music = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{4BD8D571-6D19-48D3-BE97-422220080E43}") }, // FOLDERID_Music
        .videos = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{18989B1D-99B5-455B-841C-AB7C74E4DDFC}") }, // FOLDERID_Videos
        .templates = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{A63293E8-664E-48DB-A079-DF759E0509F7}") }, // FOLDERID_Templates
        .desktop = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}") }, // FOLDERID_Desktop
        .downloads = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{374DE290-123F-4565-9164-39C4925E467B}") }, // FOLDERID_Downloads
        .public = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{DFDF76A2-C82A-4D63-906A-5644AC457385}") }, // FOLDERID_Public
        .fonts = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{FD228CB7-AE11-4AE3-864C-16F3910AB8FE}") }, // FOLDERID_Fonts
        .app_menu = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{625B53C3-AB48-4EC1-BA1F-A1EF4146FC19}") }, // FOLDERID_StartMenu
        .cache = WindowsFolderSpec{ .by_env = .{ .env_var = "LOCALAPPDATA", .subdir = "Temp" } }, // %LOCALAPPDATA%\Temp
        .roaming_configuration = WindowsFolderSpec{ .by_env = .{ .env_var = "APPDATA", .subdir = null } }, // %APPDATA%
        .local_configuration = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}") }, // FOLDERID_LocalAppData
        .data = WindowsFolderSpec{ .by_env = .{ .env_var = "APPDATA", .subdir = null } }, // %LOCALAPPDATA%\Temp
        .runtime = WindowsFolderSpec{ .by_env = .{ .env_var = "LOCALAPPDATA", .subdir = "Temp" } },
    };
};

/// Stores how to find each known folder in xdg.
const xdg_folder_spec = comptime blk: {
    // workaround for zig eval branch quota when parsing the GUIDs
    @setEvalBranchQuota(10_000);
    break :blk KnownFolderConfig(XdgFolderSpec){
        .home = XdgFolderSpec{ .env = .{ .name = "HOME", .user_dir = false, .suffix = null }, .default = null },
        .documents = XdgFolderSpec{ .env = .{ .name = "XDG_DOCUMENTS_DIR", .user_dir = true, .suffix = null }, .default = "/Documents" },
        .pictures = XdgFolderSpec{ .env = .{ .name = "XDG_PICTURES_DIR", .user_dir = true, .suffix = null }, .default = "/Pictures" },
        .music = XdgFolderSpec{ .env = .{ .name = "XDG_MUSIC_DIR", .user_dir = true, .suffix = null }, .default = "/Music" },
        .videos = XdgFolderSpec{ .env = .{ .name = "XDG_VIDEOS_DIR", .user_dir = true, .suffix = null }, .default = "/Videos" },
        .templates = XdgFolderSpec{ .env = .{ .name = "XDG_TEMPLATES_DIR", .user_dir = true, .suffix = null }, .default = "/Templates" },
        .desktop = XdgFolderSpec{ .env = .{ .name = "XDG_DESKTOP_DIR", .user_dir = true, .suffix = null }, .default = "/Desktop" },
        .downloads = XdgFolderSpec{ .env = .{ .name = "XDG_DOWNLOAD_DIR", .user_dir = true, .suffix = null }, .default = "/Downloads" },
        .public = XdgFolderSpec{ .env = .{ .name = "XDG_PUBLICSHARE_DIR", .user_dir = true, .suffix = null }, .default = "/Public" },
        .fonts = XdgFolderSpec{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = "/fonts" }, .default = "/.local/share/fonts" },
        .app_menu = XdgFolderSpec{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = "/applications" }, .default = "/.local/share/applications" },
        .cache = XdgFolderSpec{ .env = .{ .name = "XDG_CACHE_HOME", .user_dir = false, .suffix = null }, .default = "/.cache" },
        .roaming_configuration = XdgFolderSpec{ .env = .{ .name = "XDG_CONFIG_HOME", .user_dir = false, .suffix = null }, .default = "/.config" },
        .local_configuration = XdgFolderSpec{ .env = .{ .name = "XDG_CONFIG_HOME", .user_dir = false, .suffix = null }, .default = "/.config" },
        .data = XdgFolderSpec{ .env = .{ .name = "XDG_DATA_HOME", .user_dir = false, .suffix = null }, .default = "/.local/share" },
        .runtime = XdgFolderSpec{ .env = .{ .name = "XDG_RUNTIME_DIR", .user_dir = false, .suffix = null }, .default = null },
    };
};

// Ref decls
comptime {
    _ = KnownFolder;
    _ = Error;
    _ = open;
    _ = getPath;
}

test "query each known folders" {
    inline for (std.meta.fields(KnownFolder)) |fld| {
        var path_or_null = try getPath(std.testing.allocator, @field(KnownFolder, fld.name));
        if (path_or_null) |path| {
            // TODO: Remove later
            std.debug.warn("{} => '{}'\n", .{ fld.name, path });
            std.testing.allocator.free(path);
        }
    }
}

test "open each known folders" {
    inline for (std.meta.fields(KnownFolder)) |fld| {
        var dir_or_null = open(std.testing.allocator, @field(KnownFolder, fld.name), .{ .iterate = false, .access_sub_paths = true }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        if (dir_or_null) |*dir| {
            dir.close();
        }
    }
}
