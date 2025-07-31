// Use Win32 ASCII api when possible to reduce static string size in binary.
// We return WTF-16 since it'll be joined with a path later which is WTF-16.
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

const root = @import("root");
const mem = @import("mem.zig");
const unicode = @import("unicode.zig");
const os = @import("os.zig");
const OsStr = os.OsStr;
const OsStrMut = os.OsStrMut;

const darktide_class_path =
    \\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Families\FatsharkAB.Warhammer40000DarktideNew_hwm6pnepa3ng2
;
const registry_package_full_name =
    \\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository\Cache\Package\Index\PackageFullName
;
const registry_package_index =
    \\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository\Cache\Package\Data
;
const installed_location = os.into_os_str("InstalledLocation");

const steam_current_user =
    \\SOFTWARE\Valve\Steam
;
const steam_local_machine =
    \\SOFTWARE\\WOW6432Node\\Valve\\Steam
;
const steam_path = os.into_os_str("SteamPath");
const install_path = os.into_os_str("InstallPath");
const library_vdf = if (builtin.os.tag == .windows) path: {
    break :path os.into_os_str("steamapps\\libraryfolders.vdf");
} else path: {
    break :path "steamapps/libraryfolders.vdf";
};

const REG_SZ = 1;

pub extern "advapi32" fn RegOpenKeyExA(
    hKey: windows.HKEY,
    lpSubKey: windows.LPCSTR,
    ulOptions: windows.DWORD,
    samDesired: windows.REGSAM,
    phkResult: *windows.HKEY,
) callconv(.winapi) windows.LSTATUS;

pub extern "advapi32" fn RegEnumKeyExA(
    hKey: windows.HKEY,
    dwIndex: windows.DWORD,
    lpName: windows.LPSTR,
    lpcchName: *windows.DWORD,
    lpReserved: ?*windows.DWORD,
    lpClass: ?windows.LPSTR,
    lpcchClass: ?*windows.DWORD,
    lpftLastWriteTime: ?*anyopaque, //PFILETIME
) callconv(.winapi) windows.LSTATUS;

pub extern "advapi32" fn RegQueryValueExW(
    hKey: windows.HKEY,
    lpValueName: ?windows.LPCWSTR,
    lpReserved: ?*windows.DWORD,
    lpType: ?*windows.DWORD,
    lpData: ?[*]u8, //LPBYTE
    lpcbData: ?*windows.DWORD,
) callconv(.winapi) windows.LSTATUS;

fn open_key(key: windows.HKEY, path: [:0]const u8) error{KeyNotFound}!windows.HKEY {
    var out_key: windows.HKEY = undefined;
    const err_int = RegOpenKeyExA(
        key,
        path,
        0,
        windows.KEY_QUERY_VALUE | windows.KEY_ENUMERATE_SUB_KEYS,
        &out_key,
    );
    if (err_int != 0) return error.KeyNotFound;
    return out_key;
}

fn key_first_enum(key: windows.HKEY, out: [:0]u8) error{KeyNotFound}!u32 {
    var size: windows.DWORD = @intCast(out.len);
    const err_int = RegEnumKeyExA(
        key,
        0,
        out,
        &size,
        null,
        null,
        null,
        null,
    );
    if (err_int != 0) return error.KeyNotFound;
    return size;
}

fn key_get_value(key: windows.HKEY, name: [:0]const u16, out: []u16) error{KeyNotFound, Unsupported}!u32 {
    var out_type: windows.DWORD = 0;
    const out_u8: []u8 = @ptrCast(out);
    var size: windows.DWORD = @intCast(out_u8.len);
    const err_int = RegQueryValueExW(
        key,
        name,
        null,
        &out_type,
        @ptrCast(out_u8),
        &size,
    );
    if (err_int != 0) return error.KeyNotFound;
    if (out_type != REG_SZ or size % 2 != 0) return error.Unsupported;
    const size_utf16 = size / 2;
    out[size_utf16] = 0;
    return size_utf16 - 1;
}

pub fn find_darktide_gamepass(allocator: std.mem.Allocator) error{KeyNotFound, Unsupported, OutOfMemory}![:0]u16 {
    if (builtin.os.tag == .windows) {
        const apps_key = try open_key(windows.HKEY_CLASSES_ROOT, darktide_class_path);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(apps_key); };

        var buffer: [2048:0]u8 = [_:0]u8{0} ** 2048;
        var offset = registry_package_full_name.len;
        @memcpy(buffer[0..offset], registry_package_full_name);
        buffer[offset] = '\\';
        offset += 1;
        const app_name = buffer[offset..];
        _ = try key_first_enum(apps_key, app_name);

        const indexes_key = try open_key(windows.HKEY_LOCAL_MACHINE, &buffer);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(indexes_key); };

        offset = registry_package_index.len;
        @memcpy(buffer[0..offset], registry_package_index);
        buffer[offset] = '\\';
        offset += 1;
        const index = buffer[offset..];
        _ = try key_first_enum(indexes_key, index);

        const app_info_key = try open_key(windows.HKEY_LOCAL_MACHINE, &buffer);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(app_info_key); };

        const out_buffer = try allocator.allocSentinel(u16, 2047, 0);
        errdefer if (!root.leak_resources) allocator.free(out_buffer);

        const size = try key_get_value(app_info_key, installed_location, out_buffer);
        const out = try allocator.allocSentinel(u16, size, 0);
        @memcpy(out, out_buffer[0..size]);
        return out;
    } else {
        @compileError("find_darktide_gamepass is only supported on windows");
    }
}

fn steam_dir_reg(out: []u16) error{KeyNotFound, Unsupported}!u32 {
    if (open_key(windows.HKEY_CURRENT_USER, steam_current_user)) |key| open: {
        return key_get_value(key, steam_path, out) catch break :open;
    } else |_| {}

    if (open_key(windows.HKEY_LOCAL_MACHINE, steam_local_machine)) |key| open: {
        return key_get_value(key, install_path, out) catch break :open;
    } else |_| {}

    return error.KeyNotFound;
}

fn parse_string(data: []const u8, out: []u8) ?u32 {
    if (data[0] != '"') return null;

    var read: u32 = 1;
    var wrote: u32 = 0;
    while (read < data.len) {
        if (data[read] == '\\') {
            read += 1;
            out[wrote] = switch (data[read]) {
                '"', 'r', 'n', '\\' => data[read],
                else => return null,
            };
        } else if (data[read] == '"') {
            read += 1;
            break;
        } else {
            out[wrote] = data[read];
        }
        wrote += 1;
        read += 1;
    }

    if (wrote > 0) return wrote
    else return null;
}

fn find_game_path(allocator: std.mem.Allocator, path_buffer: OsStrMut, len: usize) error{OutOfMemory, InvalidUtf8, NotFoundDarktide}!OsStr {
    // Steam stores the game path in appmanifest_*.acf
    // We may need to handle that.
    const darktide_suffix = os.into_os_str(
        if (builtin.os.tag == .windows)
            \\steamapps\common\Warhammer 40,000 DARKTIDE\bundle
        else "steamapps/common/Warhammer 40,000 DARKTIDE/bundle"
    );

    const vdf_path = "\n\t\t\"path\"";
    const darktide_id = "\n\t\t\t\"1361210";
    const end_apps = "\n\t\t}";

    const data = os.read_file(allocator, path_buffer[0..len :0]) catch return error.NotFoundDarktide;
    defer if (!root.leak_resources) allocator.free(data);

    var index: usize = 0;
    var buffer: [2048:0]u8 = [_:0]u8{0} ** 2048;
    while (index < data.len) {
        index = mem.index_of_pos(data, index, vdf_path)
            orelse return error.NotFoundDarktide;
        index += vdf_path.len;
        while (data[index] != '"') index += 1;
        const size = parse_string(data[index..], &buffer) orelse return error.NotFoundDarktide;
        const path_utf8 = buffer[0..size];

        const end = mem.index_of_pos(data, index, end_apps)
            orelse return error.NotFoundDarktide;

        if (mem.index_of_pos(data[index..end], 0, darktide_id)) |_| {
            if (builtin.os.tag == .windows) {
                var utf16_size: usize = try unicode.bad_utf8_to_utf16(path_utf8, path_buffer);
                path_buffer[utf16_size] = '\\';
                utf16_size += 1;
                @memcpy(path_buffer[utf16_size..utf16_size + darktide_suffix.len], darktide_suffix);
                utf16_size += darktide_suffix.len;

                var out = try allocator.allocSentinel(u16, utf16_size, 0);
                @memcpy(out[0..utf16_size], path_buffer[0..utf16_size]);
                return out[0..utf16_size :0];
            } else {
                var out = try allocator.allocSentinel(u8, size + 1 + darktide_suffix.len, 0);
                var offset: usize = size;
                @memcpy(out[0..size], path_utf8);
                out[offset] = '/';
                offset += 1;
                @memcpy(out[offset..], darktide_suffix);
                return out;
            }
        }
    }
    return error.NotFoundDarktide;
}

pub fn find_darktide_steam(allocator: std.mem.Allocator) error{OutOfMemory, InvalidUtf8, BadPathName, NotFoundDarktide}!OsStr {
    if (builtin.os.tag == .windows) {
        var path_buffer = try allocator.allocSentinel(u16, 2047, 0);
        defer if (!root.leak_resources) allocator.free(path_buffer);

        const size = steam_dir_reg(path_buffer[0.. :0]) catch return error.NotFoundDarktide;
        const path_vdf = try os.path_join(allocator, path_buffer[0..size :0], library_vdf);
        defer if (!root.leak_resources) allocator.free(path_vdf);
        @memcpy(path_buffer[0..path_vdf.len], path_vdf);
        path_buffer[path_vdf.len] = 0;

        return find_game_path(allocator, path_buffer[0.. :0], path_vdf.len)
            catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NotFoundDarktide,
            };
    } else {
        var path_buffer: [2048:0]u8 = [_:0]u8{0} ** 2048;

        const home = std.posix.getenv("HOME") orelse return error.NotFoundDarktide;
        @memcpy(path_buffer[0..home.len], home);
        var offset: usize = home.len;
        if (path_buffer[offset] != '/') {
            path_buffer[offset] = '/';
            offset += 1;
        }
        const append = ".steam/steam/" ++ library_vdf;
        @memcpy(path_buffer[offset..offset + append.len], append);
        offset += append.len;
        path_buffer[offset] = 0;

        return find_game_path(allocator, path_buffer[0..path_buffer.len - 1 :0], offset)
            catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NotFoundDarktide,
            };
    }
}
