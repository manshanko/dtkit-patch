const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = std.unicode;
const assert = std.debug.assert;
const mem = std.mem;

/// Iterator that implements the Windows command-line parsing algorithm.
/// The implementation is intended to be compatible with the post-2008 C runtime,
/// but is *not* intended to be compatible with `CommandLineToArgvW` since
/// `CommandLineToArgvW` uses the pre-2008 parsing rules.
///
/// This iterator faithfully implements the parsing behavior observed from the C runtime with
/// one exception: if the command-line string is empty, the iterator will immediately complete
/// without returning any arguments (whereas the C runtime will return a single argument
/// representing the name of the current executable).
///
/// The essential parts of the algorithm are described in Microsoft's documentation:
///
/// - https://learn.microsoft.com/en-us/cpp/cpp/main-function-command-line-args?view=msvc-170#parsing-c-command-line-arguments
///
/// David Deley explains some additional undocumented quirks in great detail:
///
/// - https://daviddeley.com/autohotkey/parameters/parameters.htm#WINCRULES
pub const ArgIteratorWindows = struct {
    allocator: Allocator,
    /// Encoded as WTF-16 LE.
    cmd_line: []const u16,
    index: usize = 0,
    buffer: []u16,
    start: usize = 0,
    end: usize = 0,

    pub const InitError = error{OutOfMemory};

    /// `cmd_line_w` *must* be a WTF16-LE-encoded string.
    ///
    /// The iterator stores and uses `cmd_line_w`, so its memory must be valid for
    /// at least as long as the returned ArgIteratorWindows.
    pub fn init(allocator: Allocator, cmd_line_w: []const u16) InitError!ArgIteratorWindows {
        // This buffer must be large enough to contain contiguous NUL-terminated slices
        // of each argument.
        // - During parsing, the length of a parsed argument will always be equal to
        //   to less than its unparsed length
        // - The first argument needs one extra byte of space allocated for its NUL
        //   terminator, but for each subsequent argument the necessary whitespace
        //   between arguments guarantees room for their NUL terminator(s).
        const buffer = try allocator.alloc(u16, cmd_line_w.len + 1);
        errdefer allocator.free(buffer);

        return .{
            .allocator = allocator,
            .cmd_line = cmd_line_w,
            .buffer = buffer,
        };
    }

    /// Returns the next argument and advances the iterator. Returns `null` if at the end of the
    /// command-line string. The iterator owns the returned slice.
    pub fn next(self: *ArgIteratorWindows) ?[:0]const u16 {
        return self.nextWithStrategy(next_strategy);
    }

    const next_strategy = struct {
        const T = ?[:0]const u16;

        const eof = null;

        /// Returns '\' if any backslashes are emitted, otherwise returns `last_emitted_code_unit`.
        fn emitBackslashes(self: *ArgIteratorWindows, count: usize) void {
            for (0..count) |_| {
                self.buffer[self.end] = '\\';
                self.end += 1;
            }
        }

        fn emitCharacter(self: *ArgIteratorWindows, code_unit: u16) void {
            self.buffer[self.end] = code_unit;
            self.end += 1;
        }

        fn yieldArg(self: *ArgIteratorWindows) [:0]const u16 {
            self.buffer[self.end] = 0;
            const arg = self.buffer[self.start..self.end :0];
            self.end += 1;
            self.start = self.end;
            return arg;
        }
    };

    fn nextWithStrategy(self: *ArgIteratorWindows, comptime strategy: type) strategy.T {
        // The first argument (the executable name) uses different parsing rules.
        if (self.index == 0) {
            if (self.cmd_line.len == 0 or self.cmd_line[0] == 0) {
                // Immediately complete the iterator.
                // The C runtime would return the name of the current executable here.
                return strategy.eof;
            }

            var inside_quotes = false;
            while (true) : (self.index += 1) {
                const char = if (self.index != self.cmd_line.len)
                    mem.littleToNative(u16, self.cmd_line[self.index])
                else
                    0;
                switch (char) {
                    0 => {
                        return strategy.yieldArg(self);
                    },
                    '"' => {
                        inside_quotes = !inside_quotes;
                    },
                    ' ', '\t' => {
                        if (inside_quotes) {
                            strategy.emitCharacter(self, char);
                        } else {
                            self.index += 1;
                            return strategy.yieldArg(self);
                        }
                    },
                    else => {
                        strategy.emitCharacter(self, char);
                    },
                }
            }
        }

        // Skip spaces and tabs. The iterator completes if we reach the end of the string here.
        while (true) : (self.index += 1) {
            const char = if (self.index != self.cmd_line.len)
                mem.littleToNative(u16, self.cmd_line[self.index])
            else
                0;
            switch (char) {
                0 => return strategy.eof,
                ' ', '\t' => continue,
                else => break,
            }
        }

        // Parsing rules for subsequent arguments:
        //
        // - The end of the string always terminates the current argument.
        // - When not in 'inside_quotes' mode, a space or tab terminates the current argument.
        // - 2n backslashes followed by a quote emit n backslashes (note: n can be zero).
        //   If in 'inside_quotes' and the quote is immediately followed by a second quote,
        //   one quote is emitted and the other is skipped, otherwise, the quote is skipped
        //   and 'inside_quotes' is toggled.
        // - 2n + 1 backslashes followed by a quote emit n backslashes followed by a quote.
        // - n backslashes not followed by a quote emit n backslashes.
        var backslash_count: usize = 0;
        var inside_quotes = false;
        while (true) : (self.index += 1) {
            const char = if (self.index != self.cmd_line.len)
                mem.littleToNative(u16, self.cmd_line[self.index])
            else
                0;
            switch (char) {
                0 => {
                    strategy.emitBackslashes(self, backslash_count);
                    return strategy.yieldArg(self);
                },
                ' ', '\t' => {
                    strategy.emitBackslashes(self, backslash_count);
                    backslash_count = 0;
                    if (inside_quotes) {
                        strategy.emitCharacter(self, char);
                    } else return strategy.yieldArg(self);
                },
                '"' => {
                    const char_is_escaped_quote = backslash_count % 2 != 0;
                    strategy.emitBackslashes(self, backslash_count / 2);
                    backslash_count = 0;
                    if (char_is_escaped_quote) {
                        strategy.emitCharacter(self, '"');
                    } else {
                        if (inside_quotes and
                            self.index + 1 != self.cmd_line.len and
                            mem.littleToNative(u16, self.cmd_line[self.index + 1]) == '"')
                        {
                            strategy.emitCharacter(self, '"');
                            self.index += 1;
                        } else {
                            inside_quotes = !inside_quotes;
                        }
                    }
                },
                '\\' => {
                    backslash_count += 1;
                },
                else => {
                    strategy.emitBackslashes(self, backslash_count);
                    backslash_count = 0;
                    strategy.emitCharacter(self, char);
                },
            }
        }
    }

    /// Frees the iterator's copy of the command-line string and all previously returned
    /// argument slices.
    pub fn deinit(self: *ArgIteratorWindows) void {
        self.allocator.free(self.buffer);
    }
};

test ArgIteratorWindows {
    const t = testArgIteratorWindows;

    try t(
        \\"C:\Program Files\zig\zig.exe" run .\src\main.zig -target x86_64-windows-gnu -O ReleaseSafe -- --emoji=🗿 --eval="new Regex(\"Dwayne \\\"The Rock\\\" Johnson\")"
    , &.{
        \\C:\Program Files\zig\zig.exe
        ,
        \\run
        ,
        \\.\src\main.zig
        ,
        \\-target
        ,
        \\x86_64-windows-gnu
        ,
        \\-O
        ,
        \\ReleaseSafe
        ,
        \\--
        ,
        \\--emoji=🗿
        ,
        \\--eval=new Regex("Dwayne \"The Rock\" Johnson")
        ,
    });

    // Empty
    try t("", &.{});

    // Separators
    try t("aa bb cc", &.{ "aa", "bb", "cc" });
    try t("aa\tbb\tcc", &.{ "aa", "bb", "cc" });
    try t("aa\nbb\ncc", &.{"aa\nbb\ncc"});
    try t("aa\r\nbb\r\ncc", &.{"aa\r\nbb\r\ncc"});
    try t("aa\rbb\rcc", &.{"aa\rbb\rcc"});
    try t("aa\x07bb\x07cc", &.{"aa\x07bb\x07cc"});
    try t("aa\x7Fbb\x7Fcc", &.{"aa\x7Fbb\x7Fcc"});
    try t("aa🦎bb🦎cc", &.{"aa🦎bb🦎cc"});

    // Leading/trailing whitespace
    try t("  ", &.{""});
    try t("  aa  bb  ", &.{ "", "aa", "bb" });
    try t("\t\t", &.{""});
    try t("\t\taa\t\tbb\t\t", &.{ "", "aa", "bb" });
    try t("\n\n", &.{"\n\n"});
    try t("\n\naa\n\nbb\n\n", &.{"\n\naa\n\nbb\n\n"});

    // Executable name with quotes/backslashes
    try t("\"aa bb\tcc\ndd\"", &.{"aa bb\tcc\ndd"});
    try t("\"", &.{""});
    try t("\"\"", &.{""});
    try t("\"\"\"", &.{""});
    try t("\"\"\"\"", &.{""});
    try t("\"\"\"\"\"", &.{""});
    try t("aa\"bb\"cc\"dd", &.{"aabbccdd"});
    try t("aa\"bb cc\"dd", &.{"aabb ccdd"});
    try t("\"aa\\\"bb\"", &.{"aa\\bb"});
    try t("\"aa\\\\\"", &.{"aa\\\\"});
    try t("aa\\\"bb", &.{"aa\\bb"});
    try t("aa\\\\\"bb", &.{"aa\\\\bb"});

    // Arguments with quotes/backslashes
    try t(". \"aa bb\tcc\ndd\"", &.{ ".", "aa bb\tcc\ndd" });
    try t(". aa\" \"bb\"\t\"cc\"\n\"dd\"", &.{ ".", "aa bb\tcc\ndd" });
    try t(". ", &.{"."});
    try t(". \"", &.{ ".", "" });
    try t(". \"\"", &.{ ".", "" });
    try t(". \"\"\"", &.{ ".", "\"" });
    try t(". \"\"\"\"", &.{ ".", "\"" });
    try t(". \"\"\"\"\"", &.{ ".", "\"\"" });
    try t(". \"\"\"\"\"\"", &.{ ".", "\"\"" });
    try t(". \" \"", &.{ ".", " " });
    try t(". \" \"\"", &.{ ".", " \"" });
    try t(". \" \"\"\"", &.{ ".", " \"" });
    try t(". \" \"\"\"\"", &.{ ".", " \"\"" });
    try t(". \" \"\"\"\"\"", &.{ ".", " \"\"" });
    try t(". \" \"\"\"\"\"\"", &.{ ".", " \"\"\"" });
    try t(". \\\"", &.{ ".", "\"" });
    try t(". \\\"\"", &.{ ".", "\"" });
    try t(". \\\"\"\"", &.{ ".", "\"" });
    try t(". \\\"\"\"\"", &.{ ".", "\"\"" });
    try t(". \\\"\"\"\"\"", &.{ ".", "\"\"" });
    try t(". \\\"\"\"\"\"\"", &.{ ".", "\"\"\"" });
    try t(". \" \\\"", &.{ ".", " \"" });
    try t(". \" \\\"\"", &.{ ".", " \"" });
    try t(". \" \\\"\"\"", &.{ ".", " \"\"" });
    try t(". \" \\\"\"\"\"", &.{ ".", " \"\"" });
    try t(". \" \\\"\"\"\"\"", &.{ ".", " \"\"\"" });
    try t(". \" \\\"\"\"\"\"\"", &.{ ".", " \"\"\"" });
    try t(". aa\\bb\\\\cc\\\\\\dd", &.{ ".", "aa\\bb\\\\cc\\\\\\dd" });
    try t(". \\\\\\\"aa bb\"", &.{ ".", "\\\"aa", "bb" });
    try t(". \\\\\\\\\"aa bb\"", &.{ ".", "\\\\aa bb" });

    // From https://learn.microsoft.com/en-us/cpp/cpp/main-function-command-line-args#results-of-parsing-command-lines
    try t(
        \\foo.exe "abc" d e
    , &.{ "foo.exe", "abc", "d", "e" });
    try t(
        \\foo.exe a\\b d"e f"g h
    , &.{ "foo.exe", "a\\\\b", "de fg", "h" });
    try t(
        \\foo.exe a\\\"b c d
    , &.{ "foo.exe", "a\\\"b", "c", "d" });
    try t(
        \\foo.exe a\\\\"b c" d e
    , &.{ "foo.exe", "a\\\\b c", "d", "e" });
    try t(
        \\foo.exe a"b"" c d
    , &.{ "foo.exe", "ab\" c d" });

    // From https://daviddeley.com/autohotkey/parameters/parameters.htm#WINCRULESEX
    try t("foo.exe CallMeIshmael", &.{ "foo.exe", "CallMeIshmael" });
    try t("foo.exe \"Call Me Ishmael\"", &.{ "foo.exe", "Call Me Ishmael" });
    try t("foo.exe Cal\"l Me I\"shmael", &.{ "foo.exe", "Call Me Ishmael" });
    try t("foo.exe CallMe\\\"Ishmael", &.{ "foo.exe", "CallMe\"Ishmael" });
    try t("foo.exe \"CallMe\\\"Ishmael\"", &.{ "foo.exe", "CallMe\"Ishmael" });
    try t("foo.exe \"Call Me Ishmael\\\\\"", &.{ "foo.exe", "Call Me Ishmael\\" });
    try t("foo.exe \"CallMe\\\\\\\"Ishmael\"", &.{ "foo.exe", "CallMe\\\"Ishmael" });
    try t("foo.exe a\\\\\\b", &.{ "foo.exe", "a\\\\\\b" });
    try t("foo.exe \"a\\\\\\b\"", &.{ "foo.exe", "a\\\\\\b" });

    // Surrogate pair encoding of 𐐷 separated by quotes.
    // Encoded as WTF-16:
    // "<0xD801>"<0xDC37>
    // Encoded as WTF-8:
    // "<0xED><0xA0><0x81>"<0xED><0xB0><0xB7>
    // During parsing, the quotes drop out and the surrogate pair
    // should end up encoded as its normal UTF-8 representation.
    try t("foo.exe \"\xed\xa0\x81\"\xed\xb0\xb7", &.{ "foo.exe", "𐐷" });
}

// based on std.process.ArgIteratorWindows.next_strategy.emitCharacter
fn wtf16ToWtf8(allocator: std.mem.Allocator, wtf16le_slice: []const u16) ![:0]const u8 {
    var buffer = try allocator.allocSentinel(u8, std.unicode.calcWtf8Len(wtf16le_slice), 0);

    var end_index: usize = 0;
    var last_emitted_code_unit: ?u16 = null;
    for (wtf16le_slice) |code_unit| {
        if (last_emitted_code_unit != null and
            std.unicode.utf16IsLowSurrogate(code_unit) and
            std.unicode.utf16IsHighSurrogate(last_emitted_code_unit.?))
        {
            const codepoint = std.unicode.utf16DecodeSurrogatePair(&.{ last_emitted_code_unit.?, code_unit }) catch unreachable;

            const dest = buffer[end_index - 3 ..];
            const len = unicode.utf8Encode(codepoint, dest) catch unreachable;
            assert(len == 4);
            end_index += 1;
            continue;
        }

        const wtf8_len = std.unicode.wtf8Encode(code_unit, buffer[end_index..]) catch unreachable;
        end_index += wtf8_len;
        last_emitted_code_unit = code_unit;
    }
    return buffer[0..end_index :0];
}

fn testArgIteratorWindows(comptime cmd_line: [:0]const u8, comptime expected_args: []const [:0]const u8) !void {
    const cmd_line_w = try unicode.wtf8ToWtf16LeAllocZ(std.testing.allocator, cmd_line);
    defer std.testing.allocator.free(cmd_line_w);

    // next
    {
        var it = try ArgIteratorWindows.init(std.testing.allocator, cmd_line_w);
        defer it.deinit();

        for (expected_args) |expected| {
            if (it.next()) |actual_w| {
                const actual = try wtf16ToWtf8(std.testing.allocator, actual_w);
                defer std.testing.allocator.free(actual);
                try std.testing.expectEqualStrings(expected, actual);
            } else {
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expect(it.next() == null);
    }
}
