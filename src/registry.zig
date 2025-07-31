// Use Win32 ASCII api when possible to reduce static string size in binary.
// Return WTF-16 when it'll be joined with a path later.
const windows = @import("std").os.windows;

const root = @import("root");

extern "advapi32" fn RegOpenKeyExA(
    hKey: windows.HKEY,
    lpSubKey: windows.LPCSTR,
    ulOptions: windows.DWORD,
    samDesired: windows.REGSAM,
    phkResult: *windows.HKEY,
) callconv(.winapi) windows.LSTATUS;

extern "advapi32" fn RegEnumKeyExA(
    hKey: windows.HKEY,
    dwIndex: windows.DWORD,
    lpName: windows.LPSTR,
    lpcchName: *windows.DWORD,
    lpReserved: ?*windows.DWORD,
    lpClass: ?windows.LPSTR,
    lpcchClass: ?*windows.DWORD,
    lpftLastWriteTime: ?*anyopaque, //PFILETIME
) callconv(.winapi) windows.LSTATUS;

const REG_SZ = 1;

extern "advapi32" fn RegQueryValueExW(
    hKey: windows.HKEY,
    lpValueName: ?windows.LPCWSTR,
    lpReserved: ?*windows.DWORD,
    lpType: ?*windows.DWORD,
    lpData: ?[*]u8, //LPBYTE
    lpcbData: ?*windows.DWORD,
) callconv(.winapi) windows.LSTATUS;

pub const RegKey = struct {
    const Self = @This();

    pub const HKEY_CLASSES_ROOT = Self{ .key = windows.HKEY_CLASSES_ROOT };
    pub const HKEY_CURRENT_USER = Self{ .key = windows.HKEY_CURRENT_USER };
    pub const HKEY_LOCAL_MACHINE = Self{ .key = windows.HKEY_LOCAL_MACHINE };

    key: windows.HKEY,

    pub fn open(dir: Self, path: [:0]const u8) error{KeyNotFound}!Self {
        var key: windows.HKEY = undefined;
        const err_int = RegOpenKeyExA(
            dir.key,
            path,
            0,
            windows.KEY_QUERY_VALUE | windows.KEY_ENUMERATE_SUB_KEYS,
            &key,
        );
        if (err_int != 0) return error.KeyNotFound;
        return .{
            .key = key,
        };
    }

    pub fn close(self: Self) void {
        if (!root.leak_resources) {
            _ = windows.advapi32.RegCloseKey(self.key);
        }
    }

    pub fn first_enum(self: Self, out: [:0]u8) error{KeyNotFound}!u32 {
        var size: windows.DWORD = @intCast(out.len);
        const err_int = RegEnumKeyExA(
            self.key,
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

    pub fn get_value(self: Self, name: [:0]const u16, out: []u16) error{KeyNotFound, Unsupported}!u32 {
        var out_type: windows.DWORD = 0;
        const out_u8: []u8 = @ptrCast(out);
        var size: windows.DWORD = @intCast(out_u8.len);
        const err_int = RegQueryValueExW(
            self.key,
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
};
