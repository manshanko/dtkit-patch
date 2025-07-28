const builtin = @import("builtin");
const std = @import("std");

const alloc = @import("alloc.zig");
const mem = @import("mem.zig");
const cli = @import("cli.zig");
const find = @import("find.zig");

const os = @import("os.zig");
const OsStr = os.OsStr;

pub const disable_memcpy = builtin.mode == .ReleaseSmall;
pub const leak_resources = disable_memcpy;

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

pub fn main() u8 {
    const code: u8 = if (execute()) |msg| blk: {
        print(msg);
        break :blk 0;
    } else |err| blk: {
        error_print(patch_error_msg(err));
        if (os.console_will_close()) _ = os.display_message(patch_error_msg(err), .NotifyError);
        break :blk 1;
    };

    return code;
}

fn execute() ![]const u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (!leak_resources) std.debug.assert(gpa.deinit() == .ok);
    const allocator = if (leak_resources) alloc.leaky_allocator else gpa.allocator();

    var args = try os.ArgIterator.init(allocator);
    defer if (!leak_resources) args.deinit();
    _ = args.next(); // ignore bin arg

    const options = cli.PatchOptions.init(&args);
    if (options.help or (options.num_args == 0 and !os.console_will_close())) {
        return cli.help_msg();
    }

    const dir = if (options.path) |path| dir: {
        break :dir path;
    } else dir: {
        if (find.find_darktide_steam(allocator)) |path| {
            break :dir path;
        } else |_| {}

        if (builtin.os.tag == .windows) {
            break :dir find.find_darktide_gamepass(allocator) catch return error.NotFoundDarktide;
        }

        return error.NotFoundDarktide;
    };
    defer if (!leak_resources and options.path == null) allocator.free(dir);

    const db_path = try os.path_join(allocator, dir, BUNDLE_DATABASE_OS);
    defer if (!leak_resources) allocator.free(db_path);

    const db_bak_path = try os.path_join(allocator, dir, BUNDLE_DATABASE_BAK_OS);
    defer if (!leak_resources) allocator.free(db_bak_path);

    if (options.patch) {
        const result = try apply_patch(allocator, db_path, db_bak_path);
        return switch (result) {
            .AlreadyPatched => patch_error_msg(error.AlreadyPatched),
            .AppliedPatch => "successfully patched \"" ++ BUNDLE_DATABASE ++ "\"",
        };
    } else if (options.unpatch) {
        const result = try remove_patch(allocator, db_path, db_bak_path);
        return switch (result) {
            .RemovedPatch => "successfully removed patch from \"" ++ BUNDLE_DATABASE ++ "\"",
            .NotPatched => "\"" ++ BUNDLE_DATABASE ++ "\" is not patched",
        };
    } else {
        const interactive = options.interactive or (!options.toggle and os.console_will_close());

        // Default to toggle so running without arguments works (i.e. Explorer).
        const result = try toggle_patch(allocator, db_path, db_bak_path, interactive);
        return switch (result) {
            .AlreadyPatched => patch_error_msg(error.AlreadyPatched),
            .AppliedPatch => "successfully patched \"" ++ BUNDLE_DATABASE ++ "\"",
            .RemovedPatch => "successfully removed patch from \"" ++ BUNDLE_DATABASE ++ "\"",
        };
    }
}

const ToggleResult = enum {
    AlreadyPatched,
    AppliedPatch,
    RemovedPatch,
};

const PatchResult = enum {
    AlreadyPatched,
    AppliedPatch,
};

const UnpatchResult = enum {
    RemovedPatch,
    NotPatched,
};

fn toggle_patch(allocator: std.mem.Allocator, db_path: OsStr, db_bak_path: OsStr, interactive: bool) !ToggleResult {
    if (apply_patch(allocator, db_path, db_bak_path)) |result| {
        return switch (result) {
            .AlreadyPatched => {
                if (!interactive or os.display_message("Darktide is already patched.\nWould you like to remove the path?", .Prompt)) {
                    try restore_backup(db_path, db_bak_path);
                    return .RemovedPatch;
                } else {
                    return .AlreadyPatched;
                }
            },
            .AppliedPatch => {
                if (interactive) _ = os.display_message("Successfully patched Darktide to load mods.", .Notify);
                return .AppliedPatch;
            }
        };
    } else |e| {
        return e;
    }
}

fn remove_patch(allocator: std.mem.Allocator, db_path: OsStr, db_bak_path: OsStr) !UnpatchResult {
    const data = try os.read_file(allocator, db_path);
    defer if (!leak_resources) allocator.free(data);

    if (scan_database(data)) |_| {
        return .NotPatched;
    } else |e| {
        if (e == error.AlreadyPatched) {
            try restore_backup(db_path, db_bak_path);
            return .RemovedPatch;
        } else {
            return e;
        }
    }
}

noinline fn write_chunk(file: *std.fs.File, chunk: []const u8) !void {
    _ = try file.writeAll(chunk);
}

fn apply_patch(allocator: std.mem.Allocator, db_path: OsStr, db_bak_path: OsStr) !PatchResult {
    const data = try os.read_file(allocator, db_path);
    defer if (!leak_resources) allocator.free(data);

    const offset = scan_database(data) catch |e| switch (e) {
        error.AlreadyPatched => return .AlreadyPatched,
        else => return e,
    };

    // create backup database
    os.fs_rename(db_path, db_bak_path) catch |err| return switch (err) {
        error.FileNotFound => error.NotFoundDatabase,
        else => return err,
    };

    // write patched database
    var db = try os.fs_createFile(db_path);
    _ = try db.writeAll(data[0..offset]);
    _ = try db.writeAll(MOD_PATCH);
    _ = try db.writeAll(data[offset + OLD_SIZE..]);

    return .AppliedPatch;
}

fn restore_backup(db_path: OsStr, db_bak_path: OsStr) !void {
    os.fs_rename(db_bak_path, db_path) catch |err| return switch (err) {
        error.FileNotFound => error.NotFoundBackup,
        else => return err,
    };
}

fn scan_database(data: []const u8) !usize {
    // look for patch offset
    if (mem.index_of_pos(data, 0, MOD_PATCH_STARTING_POINT)) |offset| {
        const slice = data[offset..offset + 512];

        // already patched
        if (mem.index_of_pos(slice, 0, MOD_PATCH_TAG)) |_| {
            return error.AlreadyPatched;
        }

        // unhandled bundle patch
        if (mem.index_of_pos(slice, 0, BOOT_BUNDLE_NEXT_PATCH)) |_| {
            return error.UnsupportedDatabase;
        }

        return offset;
    } else {
        return error.BadFormat;
    }
}

const PatchError = error{
    AlreadyPatched,
    UnsupportedDatabase,
    BadFormat,
    OutOfMemory,
    NotFoundDatabase,
    NotFoundBackup,
    NotFoundDarktide,
};

fn patch_error_msg(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.AlreadyPatched => "\"" ++ BUNDLE_DATABASE ++ "\" is already patched",
        error.UnsupportedDatabase => "found unsupported changes in \"" ++ BUNDLE_DATABASE ++ "\"",
        error.BadFormat => "unknown format used in \"" ++ BUNDLE_DATABASE ++ "\"",
        error.OutOfMemory => "out of memory",
        error.NotFoundDatabase => "failed to find \"" ++ BUNDLE_DATABASE ++ "\"",
        error.NotFoundBackup => "failed to find \"" ++ BUNDLE_DATABASE_BAK ++ "\"",
        error.NotFoundDarktide => "failed to find Darktide installation directory",
        error.BadPathName => "directory is an invalid path",
        else => {
            if (builtin.mode != .ReleaseSmall) {
                std.debug.print("{}\n", .{err});
            }
            return "unexpected error";
        }
    };
}

fn io_stderr() std.fs.File {
    if (@hasDecl(std.fs.File, "stderr")) {
        // zig > 0.14.1
        return std.fs.File.stderr();
    } else {
        return std.io.getStdErr();
    }
}

fn print(text: []const u8) void {
    const stderr = io_stderr();
    _ = stderr.write(text) catch 0;
    _ = stderr.write("\n") catch 0;
}

fn error_print(text: []const u8) void {
    const stderr = io_stderr();
    _ = stderr.write("ERROR: ") catch 0;
    _ = stderr.write(text) catch 0;
    _ = stderr.write("\n") catch 0;
}

test {
    _ = @import("zig-std/process.zig");
    _ = @import("find.zig");
}
