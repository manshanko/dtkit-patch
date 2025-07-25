This directory contains patched/derived code from zig's standard library.

std.heap.page_allocator has a lot of correctedness code.
We probably don't need that.
Saved ~0.5KiB

ArgIteratorWindows in Zig's standard library returns WTF-8 but we *want* WTF-16.
Saved ~3KiB
