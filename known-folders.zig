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
// TODO: fill this in
pub const Error = error{OutOfMemory};

/// Returns a directory handle, or, if the folder does not exist, `null`.
pub fn open(allocator: *std.mem.Allocator, folder: SpecialFolder) Error!?std.fs.Dir {
    switch (std.builtin.os.tag) {
        .windows => {
            // TODO: Implement
            @panic("not implemented yet");
        },
        .macosx => {
            // TODO: Implement
            @panic("not implemented yet");
        },

        // Assume unix derivatives with XDG
        else => {
            // TODO: Implement
            @panic("not implemented yet");
        },
    }
    unreachable;
}

/// Returns the path to the folder or, if the folder does not exist, `null`.
pub fn getPath(allocator: *std.mem.Allocator, folder: SpecialFolder) Error!?[]const u8 {
    switch (std.builtin.os.tag) {
        .windows => {
            // TODO: Implement
            @panic("not implemented yet");
        },
        .macosx => {
            // TODO: Implement
            @panic("not implemented yet");
        },

        // Assume unix derivatives with XDG
        else => {
            // TODO: Implement
            @panic("not implemented yet");
        },
    }
    unreachable;
}

/// Contains the GUIDs for each available known-folder on windows
const WindowsFolderSpec = union(enum) {
    by_guid: std.os.windows.GUID,
    by_env: struct {
        root: []const u8,
        subdirs: []const []const u8,
    },
};

/// This returns a struct type with one field per SpecialFolder of type `T`.
/// used for storing different config data per field
fn SpecialFolderConfig(comptime T: type) type {
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
        system_folder: T,
        runtime: T,

        fn get(self: Self, folder: SpecialFolder) T {
            inline for (std.meta.fields(Self)) |fld| {
                if (self == @field(SpecialFolder, fld.name))
                    return @field(self, fld.name);
            }
            unreachable;
        }
    };
}

/// Stores how to find each special folder on windows.
const windows_folder_spec = comptime blk: {
    // workaround for zig eval branch quota when parsing the GUIDs
    @setEvalBranchQuota(10_000);
    break :blk SpecialFolderConfig(WindowsFolderSpec){
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
        .cache = WindowsFolderSpec{ .by_env = .{ .root = "LOCALAPPDATA", .subdirs = &[_][]const u8{"Temp"} } }, // %LOCALAPPDATA%\Temp
        .roaming_configuration = WindowsFolderSpec{ .by_env = .{ .root = "APPDATA", .subdirs = &[0][]const u8{} } }, // %APPDATA%
        .local_configuration = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}") }, // FOLDERID_LocalAppData
        .data = WindowsFolderSpec{ .by_env = .{ .root = "APPDATA", .subdirs = &[0][]const u8{} } }, // %LOCALAPPDATA%\Temp
        .system_folder = WindowsFolderSpec{ .by_guid = std.os.windows.GUID.parse("{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}") }, // FOLDERID_System
        .runtime = WindowsFolderSpec{ .by_env = .{ .root = "LOCALAPPDATA", .subdirs = &[_][]const u8{"Temp"} } },
    };
};

// Ref decls
comptime {
    _ = SpecialFolder;
    _ = Error;
    _ = open;
    _ = getPath;
}

test "query each windows known folders" {
    // TODO: Implement this test
    _ = windows_folder_spec;
}
