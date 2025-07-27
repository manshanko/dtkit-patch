// Use Win32 ASCII api when possible to reduce static string size in binary.
// We return WTF-16 since it'll be joined with a path later which is WTF-16.
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

const root = @import("root");
const mem = @import("mem.zig");
const os = @import("os.zig");

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
    return size;
}

pub fn find_darktide_gamepass(allocator: std.mem.Allocator) error{KeyNotFound, Unsupported, OutOfMemory}![:0]u16 {
    if (builtin.os.tag == .windows) {
        const apps_key = try open_key(windows.HKEY_CLASSES_ROOT, darktide_class_path);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(apps_key); };

        var buffer: [2048:0]u8 = [_:0]u8{0} ** 2048;
        var offset = registry_package_full_name.len;
        mem.memcpy(buffer[0..offset], registry_package_full_name);
        buffer[offset] = '\\';
        offset += 1;
        const app_name = buffer[offset..];
        _ = try key_first_enum(apps_key, app_name);

        const indexes_key = try open_key(windows.HKEY_LOCAL_MACHINE, &buffer);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(indexes_key); };

        offset = registry_package_index.len;
        mem.memcpy(buffer[0..offset], registry_package_index);
        buffer[offset] = '\\';
        offset += 1;
        const index = buffer[offset..];
        _ = try key_first_enum(indexes_key, index);

        const app_info_key = try open_key(windows.HKEY_LOCAL_MACHINE, &buffer);
        defer if (!root.leak_resources) { _ = windows.advapi32.RegCloseKey(app_info_key); };

        var out = try allocator.alloc(u16, 2048);
        errdefer if (!root.leak_resources) allocator.free(out);

        const size = try key_get_value(app_info_key, installed_location, out);
        out[size] = 0;
        return out[0..size :0];
    } else {
        @compileError("find_darktide_gamepass is only supported on windows");
    }
}
