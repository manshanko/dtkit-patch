// derived from std.heap.page_allocator (lib/std/heap/PageAllocator.zig)
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const ntdll = windows.ntdll;
const SUCCESS = windows.NTSTATUS.SUCCESS;

pub const page_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
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
        @compileError("custom page_allocator not implemented for other platforms");
    }
}

fn alloc(context: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    _ = context;
    _ = ra;
    std.debug.assert(n > 0);
    return map(n, alignment);
}

fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    _ = context;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ra;
    return false;
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    _ = context;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ra;
    return null;
}

// SAFETY: OS cleans up for us.
fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    _ = context;
    _ = memory;
    _ = alignment;
    _ = ra;
}
