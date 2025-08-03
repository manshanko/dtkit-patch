// Switch on error compiles to lookup tables. For small apps the lookup tables
// can be relatively large.
//
// This error string storage is O(n) lookup instead of O(1) but saves up to 2KiB.
const builtin = @import("builtin");
const std = @import("std");

const root = @import("root");
const BUNDLE_DATABASE = root.BUNDLE_DATABASE;
const BUNDLE_DATABASE_BAK = root.BUNDLE_DATABASE_BAK;

pub const PatcherError = error {
    AlreadyPatched,
    BadFormat,
    NotFoundBackup,
    NotFoundDarktide,
    NotFoundDatabase,
    UnsupportedDatabase,

    AccessDenied,
    AntivirusInterference,
    BadPathName,
    BrokenPipe,
    Canceled,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    DeviceBusy,
    DiskQuota,
    FileBusy,
    FileLocksNotSupported,
    FileNotFound,
    FileTooBig,
    InputOutput,
    InvalidUtf8,
    InvalidWtf8,
    IsDir,
    LinkQuotaExceeded,
    LockViolation,
    NameTooLong,
    NetworkNotFound,
    NoDevice,
    NoSpaceLeft,
    NotDir,
    NotOpenForReading,
    OperationAborted,
    OutOfMemory,
    PathAlreadyExists,
    PermissionDenied,
    PipeBusy,
    ProcessFdQuotaExceeded,
    ProcessNotFound,
    ReadOnlyFileSystem,
    RenameAcrossMountPoints,
    SharingViolation,
    SocketNotConnected,
    SymLinkLoop,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
    Unseekable,
    WouldBlock,

    // Linux only?
    //LimitTooBig,
} || if (builtin.mode == .Debug) error{InvalidArgument, NotOpenForWriting, MessageTooBig} else error{};

fn patcher_error_asc(_: void, lhs: std.builtin.Type.Error, rhs: std.builtin.Type.Error) bool {
    return @intFromError(@field(PatcherError, lhs.name)) < @intFromError(@field(PatcherError, rhs.name));
}

const error_set = @typeInfo(PatcherError).error_set.?;
const errors: [error_set.len]std.builtin.Type.Error = blk: {
    var list: [error_set.len]std.builtin.Type.Error = undefined;
    @memcpy(&list, error_set);
    std.sort.block(std.builtin.Type.Error, &list, void{}, patcher_error_asc);
    break :blk list;
};
const last_error: u16 = @intFromError(@field(PatcherError, errors[errors.len - 1].name));

const buffer_size: usize = size: {
    var size = 0;
    var highest = 0;
    for (errors) |err| {
        const next_index = @intFromError(@field(PatcherError, err.name));
        if (next_index > highest) highest = next_index;
        size += string_literal(err.name).len + 1;
    }
    const missing = highest - errors.len;
    size += missing;
    break :size size;
};

const lookup_buffer: [buffer_size]u8 = lookup: {
    var buffer: [buffer_size]u8 = undefined;
    var index = 0;
    var offset = 0;
    for (errors) |err| {
        const next_index = @intFromError(@field(PatcherError, err.name));
        var diff: i64 = next_index - index;
        std.debug.assert(diff > 0);
        if (diff > 1) {
            if (diff > 50) {
                @compileLog(err.name, next_index, diff);
                @compileError("bad error list");
            }
            while (diff > 1) {
                buffer[offset] = 0;
                offset += 1;
                diff -= 1;
            }
        }

        index = next_index;
        const err_msg = string_literal(err.name);
        @memcpy(buffer[offset..offset + err_msg.len], err_msg);
        offset += err_msg.len;
        buffer[offset] = 0;
        offset += 1;
    }
    break :lookup buffer;
};

pub fn lookup(err: PatcherError) [:0]const u8 {
    var index = @intFromError(err);
    if (index > last_error) return "unexpected error";
    var offset: usize = 0;
    while (index > 1) {
        if (lookup_buffer[offset] == 0) index -= 1;
        offset += 1;
    }

    std.debug.assert(index == 1);
    var len: usize = 0;
    while (lookup_buffer[offset + len] != 0) {
        len += 1;
    }
    return if (len == 0)
        "unexpected error"
    else
        lookup_buffer[offset..offset + len :0];
}

fn string_literal(comptime err_name: [:0]const u8) [:0]const u8 {
    return switch (@field(PatcherError, err_name)) {
        error.AlreadyPatched => "\"" ++ BUNDLE_DATABASE ++ "\" is already patched",
        error.BadFormat => "unknown format used in \"" ++ BUNDLE_DATABASE ++ "\"",
        error.NotFoundBackup => "failed to find \"" ++ BUNDLE_DATABASE_BAK ++ "\"",
        error.NotFoundDarktide => "failed to find Darktide installation directory",
        error.NotFoundDatabase => "failed to find \"" ++ BUNDLE_DATABASE ++ "\"",
        error.UnsupportedDatabase => "found unsupported changes in \"" ++ BUNDLE_DATABASE ++ "\"",
        error.BadPathName => "directory is an invalid path",
        else => err_name,
    };
}
