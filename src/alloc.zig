// based on std.heap.page_allocator (lib/std/heap/PageAllocator.zig)
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const ntdll = windows.ntdll;
const SUCCESS = windows.NTSTATUS.SUCCESS;

pub const leaky_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};

fn map(n: usize, alignment: std.mem.Alignment) ?[*]u8 {
    const page_size = std.heap.pageSize();
    if (n >= std.math.maxInt(usize) - page_size) return null;
    const alignment_bytes = alignment.toByteUnits();

    if (builtin.os.tag == .windows) {
        var base_addr: ?*anyopaque = null;
        var size: windows.SIZE_T = n;

        const status = ntdll.NtAllocateVirtualMemory(
            windows.GetCurrentProcess(),
            @ptrCast(&base_addr),
            0,
            &size,
            windows.MEM_COMMIT | windows.MEM_RESERVE,
            windows.PAGE_READWRITE,
        );

        if (status == SUCCESS and std.mem.isAligned(@intFromPtr(base_addr), alignment_bytes)) {
            return @ptrCast(base_addr);
        } else {
            // TODO: assert on debug
            return null;
        }
    } else {
        @compileError("leaky_allocator not implemented for other platforms");
    }
}

fn alloc(context: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    _ = context;
    _ = ra;
    std.debug.assert(n > 0);
    return map(n, alignment);
}
