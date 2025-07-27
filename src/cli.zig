const std = @import("std");

const os = @import("os.zig");
const OsStr = os.OsStr;

fn into_opt(comptime key: [:0]const u8) OsStr {
    const prefix = if (key.len == 1) res: {
        break :res "-";
    } else res: {
        break :res "--";
    };
    return os.into_os_str(prefix ++ key);
}

pub fn help_msg() []const u8 {
    return
        \\dtkit-patch 0.0.0 (smaller than ever!)
        \\https://github.com/manshanko/dtkit-patch
        \\
        \\dtkit-patch patches Darktide to load the mod entry bundle.
        \\
        \\If no option is used then dtkit-patch will patch sliently or prompt user to
        \\unpatch if Darktide is already patched.
        \\
        \\USAGE:
        \\dtkit-patch [OPTION] [DIR]
        \\
        \\OPTIONS:
        \\  --patch       Patch bundle database.
        \\  --unpatch     Unpatch bundle database.
        \\  --toggle      Toggle patch/unpatch on bundle database.
    ;
}

// Prefixs tags with dash for command line matching when parsing arguments.
const Option = enum {
    const Self = @This();

    h, help,
    patch,
    toggle,
    unpatch,

    const pointee = @typeInfo(OsStr).pointer.child;
    const fields = @typeInfo(Self).@"enum".fields;
    const Lookup = struct {
        keys: [fields.len]OsStr,
        values: [fields.len]Option,
    };
    const lookup: Lookup = res: {
        var keys: [fields.len]OsStr = undefined;
        var values: [fields.len]Self = undefined;
        var prev: ?[:0]const u8 = null;
        for (0..fields.len, fields) |i, field| {
            keys[i] = into_opt(field.name);
            values[i] = @enumFromInt(field.value);

            if (prev) |lt| {
                if (!std.mem.order(u8, lt, field.name).compare(std.math.CompareOperator.lt)) {
                    @compileError(lt ++ " is greater than " ++ field.name);
                }
            }
            prev = field.name;
        }

        break :res .{ .keys = keys, .values = values };
    };

    fn match(tag: OsStr) ?Self {
        for (0..fields.len) |i| {
            if (std.mem.eql(pointee, lookup.keys[i], tag)) {
                return lookup.values[i];
            }
        }
        return null;
    }
};

pub const PatchOptions = struct {
    const Self = @This();

    num_args: u16,
    help: bool,
    patch: bool,
    unpatch: bool,
    toggle: bool,
    path: ?OsStr,

    pub fn init(args: *os.ArgIterator) Self {
        var num_args: u16 = 0;
        var num_opts: u16 = 0;
        var help = false;
        var patch = false;
        var unpatch = false;
        var toggle = false;
        var path: ?OsStr = null;
        while (args.next()) |arg| {
            num_args += 1;
            if (num_opts > 0) {
                // TODO: ignore arg
                continue;
            }

            if (Option.match(arg)) |opt| {
                switch (opt) {
                    .h, .help => help = true,
                    .patch => patch = true,
                    .unpatch => unpatch = true,
                    .toggle => toggle = true,
                }

                if (help or patch or unpatch or toggle) {
                    num_opts = 1;
                }
                if (patch or unpatch or toggle) {
                    if (path == null) path = args.next();
                }
            } else if (path == null) {
                path = arg;
            } else {
                // TODO: log unknown option
                continue;
            }
        }

        return .{
            .num_args = num_args,
            .help = help,
            .patch = patch,
            .unpatch = unpatch,
            .toggle = toggle,
            .path = path,
        };
    }
};
