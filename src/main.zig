const builtin = @import("builtin");
const std = @import("std");

const alloc = @import("alloc.zig");
const mem = @import("mem.zig");
const cli = @import("cli.zig");
const find = @import("find.zig");

const os = @import("os.zig");
const OsStr = os.OsStr;

pub const leak_resources = builtin.mode != .Debug;

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

const already_patched_msg = "\"" ++ BUNDLE_DATABASE ++ "\" is already patched";

pub const std_options = std.Options{
    .enable_segfault_handler = !leak_resources,
};

pub const panic = if (leak_resources) std.debug.no_panic else std.debug.FullPanic(std.debug.defaultPanic);

pub fn main() u8 {
    const code: u8 = if (execute()) |msg| blk: {
        print(msg);
        break :blk 0;
    } else |err| blk: {
        const err_msg = switch (err) {
            error.AlreadyPatched => already_patched_msg,
            error.UnsupportedDatabase => "found unsupported changes in \"" ++ BUNDLE_DATABASE ++ "\"",
            error.BadFormat => "unknown format used in \"" ++ BUNDLE_DATABASE ++ "\"",
            error.OutOfMemory => "out of memory",
            error.NotFoundDatabase => "failed to find \"" ++ BUNDLE_DATABASE ++ "\"",
            error.NotFoundBackup => "failed to find \"" ++ BUNDLE_DATABASE_BAK ++ "\"",
            error.NotFoundDarktide => "failed to find Darktide installation directory",
            error.BadPathName => "directory is an invalid path",
            error.InvalidUtf8 => "invalid UTF-8",
            error.AccessDenied,
            error.PermissionDenied => "access denied",
            else => if (builtin.mode != .ReleaseSmall) @errorName(err) else "unexpected error",
        };
        error_print(err_msg);
        if (os.console_will_close()) _ = os.display_message(err_msg, .NotifyError);
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
            .AlreadyPatched => already_patched_msg,
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
            .AlreadyPatched => already_patched_msg,
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
    if (os.read_file(allocator, db_path)) |data| {
        defer if (!leak_resources) allocator.free(data);

        if (scan_database(data)) |_| {
            return .NotPatched;
        } else |err| {
            if (err != error.AlreadyPatched) {
                return err;
            }
        }
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    try restore_backup(db_path, db_bak_path);
    return .RemovedPatch;
}

fn apply_patch(allocator: std.mem.Allocator, db_path: OsStr, db_bak_path: OsStr) !PatchResult {
    const data = os.read_file(allocator, db_path) catch |e| return switch (e) {
        error.FileNotFound => error.NotFoundDarktide,
        else => e,
    };
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
    const db = try os.fs_createFile(db_path);
    for ([_][]const u8{data[0..offset], MOD_PATCH, data[offset + OLD_SIZE..]}) |chunk| {
        db.writeAll(chunk) catch |err| {
            try restore_backup(db_path, db_bak_path);
            return if (leak_resources) error.Unexpected else err;
        };
    }

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

fn print(text: []const u8) void {
    const stderr = os.stderr();
    _ = stderr.write(text) catch 0;
    _ = stderr.write("\n") catch 0;
}

fn error_print(text: []const u8) void {
    const stderr = os.stderr();
    _ = stderr.write("ERROR: ") catch 0;
    _ = stderr.write(text) catch 0;
    _ = stderr.write("\n") catch 0;
}

test {
    _ = @import("zig-std/process.zig");
    _ = @import("unicode.zig");
}
