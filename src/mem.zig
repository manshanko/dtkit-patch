// When @memcpy and @memmove fail to inline(?) it adds:
//   * ~1KiB to .text
//   * ~4KiB to .rdata
//
// This is with x86_64-windows-gnu optimizing for ReleaseSmall.
//
// I do not know the relation between the extra contents .rdata and @memcpy/@memmove.
// It looks to contain mostly f32. Zeroing it out didn't immediately crash when ran.
const root = @import("root");

pub fn memcpy(dest: anytype, src: anytype) void {
    if (root.disable_memcpy) {
        for (0..dest.len) |i| dest[i] = src[i];
    } else {
        @memcpy(dest, src);
    }
}
