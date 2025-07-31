const std = @import("std");

// Slower and smaller (~1.5KiB) UTF-8 parser than std.unicode.utf8ToUtf16Le
pub fn bad_utf8_to_utf16(utf8: []const u8, utf16: []u16) error{InvalidUtf8}!usize {
    var offset: u32 = 0;
    var dest_offset: u32 = 0;
    while (offset < utf8.len and dest_offset < utf16.len) {
        const prev_offset = offset;
        if (utf8[offset] < 0b10000000) {
            utf16[dest_offset] = utf8[offset] & 0b01111111;
            offset += 1;
            dest_offset += 1;
        } else if (utf8[offset] >= 0b11111000) {
            return error.InvalidUtf8;
        } else if (utf8[offset] >= 0b11110000) {
            if (offset + 3 >= utf8.len or dest_offset + 1 >= utf16.len) return error.InvalidUtf8;
            const b0: u32 = utf8[offset    ] & 0b00000111;
            const b1: u32 = utf8[offset + 1] & 0b00111111;
            const b2: u32 = utf8[offset + 2] & 0b00111111;
            const b3: u32 = utf8[offset + 3] & 0b00111111;
            var cp = ((b0 << 18) | (b1 << 12) | (b2 << 6) | b3);
            if (cp <= 0xffff or cp > 0x10ffff) return error.InvalidUtf8;
            cp -= 0x10000;
            const high: u16 = @intCast(0xd800 + ((cp >> 10) & 0x3ff));
            const low: u16 = @intCast(0xdc00 + (cp & 0x3ff));
            utf16[dest_offset    ] = high;
            utf16[dest_offset + 1] = low;
            offset += 4;
            dest_offset += 2;
        } else if (utf8[offset] >= 0b11100000) {
            if (offset + 2 >= utf8.len) return error.InvalidUtf8;
            const b0: u16 = utf8[offset    ] & 0b00001111;
            const b1: u16 = utf8[offset + 1] & 0b00111111;
            const b2: u16 = utf8[offset + 2] & 0b00111111;
            const cp = (b0 << 12) | (b1 << 6) | b2;
            if (cp <= 0x7ff) return error.InvalidUtf8;
            if (cp >= 0xd800 and cp <= 0xdfff) return error.InvalidUtf8;
            utf16[dest_offset] = cp;
            offset += 3;
            dest_offset += 1;
        } else if (utf8[offset] >= 0b11000000) {
            if (offset + 1 >= utf8.len) return error.InvalidUtf8;
            const b0: u16 = utf8[offset    ] & 0b00011111;
            const b1: u16 = utf8[offset + 1] & 0b00111111;
            const cp = (b0 << 6) | b1;
            if (cp <= 0x7f) return error.InvalidUtf8;
            utf16[dest_offset] = cp;
            offset += 2;
            dest_offset += 1;
        } else {
            return error.InvalidUtf8;
        }

        for (prev_offset + 1..offset) |i| {
            const c = utf8[i];
            if (c >= 0b11000000) return error.InvalidUtf8;
        }
    }
    return dest_offset;
}

// test is adapted from the test for std.unicode.utf8ToUtf16Le
// https://github.com/ziglang/zig/blob/d03a147ea0a590ca711b3db07106effc559b0fc6/lib/std/unicode.zig#L1243-L1271
//
// Copyright (c) Zig contributors
// https://github.com/ziglang/zig/blob/d03a147ea0a590ca711b3db07106effc559b0fc6/LICENSE
test bad_utf8_to_utf16 {
    var utf16le: [128]u16 = undefined;
    {
        const length = try bad_utf8_to_utf16("𐐷", utf16le[0..]);
        try std.testing.expectEqualSlices(u8, "\x01\xd8\x37\xdc", std.mem.sliceAsBytes(utf16le[0..length]));
    }
    {
        const length = try bad_utf8_to_utf16("\u{10FFFF}", utf16le[0..]);
        try std.testing.expectEqualSlices(u8, "\xff\xdb\xff\xdf", std.mem.sliceAsBytes(utf16le[0..length]));
    }
    {
        const result = bad_utf8_to_utf16("\xf4\x90\x80\x80", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const length = try bad_utf8_to_utf16("This string has been designed to test the vectorized implementat" ++
            "ion by beginning with one hundred twenty-seven ASCII characters¡", utf16le[0..]);
        try std.testing.expectEqualSlices(u8, &.{
            'T', 0, 'h', 0, 'i', 0, 's', 0, ' ', 0, 's', 0, 't', 0, 'r', 0, 'i', 0, 'n', 0, 'g', 0, ' ', 0, 'h', 0, 'a', 0, 's', 0, ' ',  0,
            'b', 0, 'e', 0, 'e', 0, 'n', 0, ' ', 0, 'd', 0, 'e', 0, 's', 0, 'i', 0, 'g', 0, 'n', 0, 'e', 0, 'd', 0, ' ', 0, 't', 0, 'o',  0,
            ' ', 0, 't', 0, 'e', 0, 's', 0, 't', 0, ' ', 0, 't', 0, 'h', 0, 'e', 0, ' ', 0, 'v', 0, 'e', 0, 'c', 0, 't', 0, 'o', 0, 'r',  0,
            'i', 0, 'z', 0, 'e', 0, 'd', 0, ' ', 0, 'i', 0, 'm', 0, 'p', 0, 'l', 0, 'e', 0, 'm', 0, 'e', 0, 'n', 0, 't', 0, 'a', 0, 't',  0,
            'i', 0, 'o', 0, 'n', 0, ' ', 0, 'b', 0, 'y', 0, ' ', 0, 'b', 0, 'e', 0, 'g', 0, 'i', 0, 'n', 0, 'n', 0, 'i', 0, 'n', 0, 'g',  0,
            ' ', 0, 'w', 0, 'i', 0, 't', 0, 'h', 0, ' ', 0, 'o', 0, 'n', 0, 'e', 0, ' ', 0, 'h', 0, 'u', 0, 'n', 0, 'd', 0, 'r', 0, 'e',  0,
            'd', 0, ' ', 0, 't', 0, 'w', 0, 'e', 0, 'n', 0, 't', 0, 'y', 0, '-', 0, 's', 0, 'e', 0, 'v', 0, 'e', 0, 'n', 0, ' ', 0, 'A',  0,
            'S', 0, 'C', 0, 'I', 0, 'I', 0, ' ', 0, 'c', 0, 'h', 0, 'a', 0, 'r', 0, 'a', 0, 'c', 0, 't', 0, 'e', 0, 'r', 0, 's', 0, '¡', 0,
        }, std.mem.sliceAsBytes(utf16le[0..length]));
    }

    // based on summary from https://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
    {
        const result = bad_utf8_to_utf16("\xc0\x00", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xc0\xc0", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xe0\x80\xcf", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xf0\x80\xcf\xcf", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xed\xa0\xcf", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
    {
        const result = bad_utf8_to_utf16("\xf4\x90\xcf\xcf", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }

    {
        const result = bad_utf8_to_utf16("\xc0", utf16le[0..]);
        try std.testing.expectError(error.InvalidUtf8, result);
    }
}
