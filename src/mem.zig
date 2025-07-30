// When @memcpy and @memmove fail to inline(?) it adds:
//   * ~1KiB to .text
//   * ~4KiB to .rdata
//
// This is with x86_64-windows-gnu optimizing for ReleaseSmall.
//
// I do not know the relation between the extra contents .rdata and @memcpy/@memmove.
// It looks to contain mostly f32. Zeroing it out didn't immediately crash when ran.
const std = @import("std");

const root = @import("root");

pub fn memcpy(dest: anytype, src: anytype) void {
    if (root.disable_memcpy) {
        for (0..dest.len) |i| dest[i] = src[i];
    } else {
        @memcpy(dest, src);
    }
}

// based on std.mem.indexOfPosLinear
pub inline fn index_of_pos(haystack: []const u8, start_index: usize, needle: []const u8) ?usize {
    if (root.disable_memcpy) {
        if (needle.len > haystack.len) return null;

        var i: usize = start_index;
        const end = haystack.len - needle.len;
        search: while (i <= end) : (i += 1) {
            for (0..needle.len) |j| if (haystack[i + j] != needle[j]) continue :search;
            return i;
        }
        return null;
    } else {
        return std.mem.indexOfPosLinear(u8, haystack, start_index, needle);
    }
}
