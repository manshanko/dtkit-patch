const builtin = @import("builtin");
const std = @import("std");

// based on std.mem.indexOfPosLinear
pub noinline fn index_of_pos(haystack: []const u8, start_index: usize, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;

    var i: usize = start_index;
    const end = haystack.len - needle.len;
    search: while (i <= end) : (i += 1) {
        for (0..needle.len) |j| if (haystack[i + j] != needle[j]) continue :search;
        return i;
    }
    return null;
}

// When @memcpy/@memmove fail to inline on x86_64-windows-gnu it adds ~5KiB overhead.
// If we export memcpy and memset symbols for ReleaseSafe/ReleaseSmall, even with the
// same implementation, it doesn't happen.
//
// Testing with x86_64-linux-gnu showed no difference.
comptime {
    if (builtin.mode != .Debug) {
        @export(&memcpy_, .{ .name = "memcpy", .linkage = .strong });
    }

    // ReleaseSmall has increased binary size if exporting our own memset so we don't.
    if (builtin.mode == .ReleaseSafe or builtin.mode == .ReleaseFast) {
        @export(&memset_, .{ .name = "memset", .linkage = .strong });
    }
}

// The memcpy_ and memset_ implementation is from compiler_rt in Zig.
//
// Copyright (c) Zig contributors
// https://github.com/ziglang/zig/blob/d03a147ea0a590ca711b3db07106effc559b0fc6/LICENSE

// zig/lib/compiler_rt/memcpy.zig
fn memcpy_(noalias dest: ?[*]u8, noalias src: ?[*]u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);

    for (0..len) |i| {
        dest.?[i] = src.?[i];
    }

    return dest;
}

// zig/lib/compiler_rt/memset.zig
fn memset_(dest: ?[*]u8, c: u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);

    if (len != 0) {
        var d = dest.?;
        var n = len;
        while (true) {
            d[0] = c;
            n -= 1;
            if (n == 0) break;
            d += 1;
        }
    }

    return dest;
}
