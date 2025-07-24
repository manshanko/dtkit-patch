const std = @import("std");

const os = @import("os.zig");
const OsStr = os.OsStr;

const BUNDLE_DATABASE = "bundle_database.data";
const BUNDLE_DATABASE_OS = os.into_os_str(BUNDLE_DATABASE);
const BUNDLE_DATABASE_BAK = "bundle_database.data.bak";
const BUNDLE_DATABASE_BAK_OS = os.into_os_str(BUNDLE_DATABASE_BAK);

const BOOT_BUNDLE_NEXT_PATCH = "9ba626afa44a3aa3.patch_001";
const OLD_SIZE: u64 = 84;
const MOD_PATCH = @embedFile("patch.bin");
const MOD_PATCH_TAG = ".patch_999";
const MOD_PATCH_STARTING_POINT_: u64 = 0xA33A4AA4AF26A69B;
const MOD_PATCH_STARTING_POINT = std.mem.asBytes(&@byteSwap(MOD_PATCH_STARTING_POINT_));

pub fn main() void {
    const allocator = std.heap.page_allocator;
    const dir = std.process.getenvW(os.into_os_str("DARKTIDE_BUNDLE_DIR"))
    orelse {
        print("ERROR: environment variable DARKTIDE_BUNDLE_DIR not set");
        std.process.exit(1);
    };

    const db_path = os.path_join(allocator, dir, BUNDLE_DATABASE_OS) catch abort(error.OutOfMemory);
    const db_bak_path = os.path_join(allocator, dir, BUNDLE_DATABASE_BAK_OS) catch abort(error.OutOfMemory);

    const res = toggle_patch(allocator, db_path, db_bak_path, false);

    res catch |e| abort(e);
}

fn abort(err: anyerror) noreturn {
    error_print(patch_error_msg(err));
    std.process.exit(1);
}

fn toggle_patch(allocator: std.mem.Allocator, db_path: OsStr, db_bak_path: OsStr, interactive: bool) !void {
    if (apply_patch(allocator, db_path, db_bak_path)) |_| {
        print("successfully patched \"" ++ BUNDLE_DATABASE ++ "\"");
    } else |e| {
        if (e == error.AlreadyPatched) {
            if (interactive and prompt_user("Darktide is already patched.\nWould you like to remove the path?")) {
                try restore_backup(db_path, db_bak_path);
            } else {
                print(patch_error_msg(error.AlreadyPatched));
            }
        } else {
            return e;
        }
    }
}

fn remove_patch(allocator: std.mem.Allocator, db_path: OsStr, db_bak_path: OsStr) !void {
    const data = try read_database(allocator, db_path);
    if (scan_database(data.buffer[0..data.read])) |_| {
        print("\"" ++ BUNDLE_DATABASE ++ "\" is already not patched");
    } else |e| {
        if (e == error.AlreadyPatched) {
            try restore_backup(db_path, db_bak_path);
        } else {
            return e;
        }
    }
}

fn apply_patch(allocator: std.mem.Allocator, db_path: OsStr, db_bak_path: OsStr) !void {
    const data = try read_database(allocator, db_path);
    const offset = try scan_database(data.buffer[0..data.read]);

    // insert data
    const extra_size = MOD_PATCH.len - OLD_SIZE;
    @memmove(
        data.buffer[offset + MOD_PATCH.len..data.read + extra_size],
        data.buffer[offset + OLD_SIZE..data.read],
    );
    @memcpy(data.buffer[offset..offset + MOD_PATCH.len], MOD_PATCH);

    // create backup database
    try os.fs_unlink(db_bak_path);
    os.fs_rename(db_path, db_bak_path) catch |err| return switch (err) {
        error.FileNotFound => error.NotFoundDatabase,
        else => return err,
    };

    // write patched database
    var db = try os.fs_createFile(db_path);
    _ = try db.write(data.buffer[0..data.read + extra_size]);
}

fn restore_backup(db_path: OsStr, db_bak_path: OsStr) !void {
    os.fs_unlink(db_path) catch |err| return switch (err) {
        error.FileNotFound => error.NotFoundBackup,
        else => return err,
    };
    os.fs_rename(db_bak_path, db_path) catch |err| return switch (err) {
        error.FileNotFound => error.NotFoundBackup,
        else => return err,
    };
}

fn scan_database(data: []const u8) !usize {
    // look for patch offset
    if (std.mem.indexOfPosLinear(u8, data, 0, MOD_PATCH_STARTING_POINT)) |offset| {
        const slice = data[offset..offset + 512];

        // already patched
        if (std.mem.indexOfPosLinear(u8, slice, 0, MOD_PATCH_TAG)) |_| {
            return error.AlreadyPatched;
        }

        // unhandled bundle patch
        if (std.mem.indexOfPosLinear(u8, slice, 0, BOOT_BUNDLE_NEXT_PATCH)) |_| {
            return error.Unsupported;
        }

        return offset;
    } else {
        return error.BadFormat;
    }
}

const file_data = struct {
    buffer: []u8,
    read: usize,
};

fn read_database(allocator: std.mem.Allocator, path: OsStr) !file_data {
    const file = os.fs_openFile(path) catch |err| return switch (err) {
        error.FileNotFound => error.NotFoundDatabase,
        //error.BadPathName => {
        //    std.debug.print("{f}\n", .{std.unicode.fmtUtf16Le(database_path)});
        //    return null;
        //},
        else => return err,
    };
    //defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    const data = try allocator.alloc(u8, size + MOD_PATCH.len);
    const read = try file.readAll(data[0..size]);
    return .{
        .buffer = data,
        .read = read,
    };
}

fn prompt_user(comptime msg: [:0]const u8) bool {
    const msg_wide = comptime os.into_os_str(msg);
    _ = &msg_wide;
    return false;
}

const PatchError = error{
    AlreadyPatched,
    Unsupported,
    BadFormat,
    OutOfMemory,
    NotFoundDatabase,
    NotFoundBackup,
};

fn patch_error_msg(err: anyerror) []const u8 {
    return switch (err) {
        error.AlreadyPatched => "\"" ++ BUNDLE_DATABASE ++ "\" is already patched",
        error.Unsupported => "found unsupported changes in \"" ++ BUNDLE_DATABASE ++ "\"",
        error.BadFormat => "unknown format used in \"" ++ BUNDLE_DATABASE ++ "\"",
        error.OutOfMemory => "out of memory",
        error.NotFoundDatabase => "failed to find \"" ++ BUNDLE_DATABASE ++ "\"",
        error.NotFoundBackup => "failed to find \"" ++ BUNDLE_DATABASE_BAK ++ "\"",
        else => "unexpected error",
    };
}

fn print(text: []const u8) void {
    const stderr = std.fs.File.stderr();
    _ = stderr.write(text) catch 0;
    _ = stderr.write("\n") catch 0;
}

fn error_print(text: []const u8) void {
    const stderr = std.fs.File.stderr();
    _ = stderr.write("ERROR: ") catch 0;
    _ = stderr.write(text) catch 0;
    _ = stderr.write("\n") catch 0;
}
