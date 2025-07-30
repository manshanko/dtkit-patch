Toy project to learn Zig while writing a smaller dtkit-patch.

Size optimizations include:
1. avoid WTF-8 <-> WTF-16 conversions
2. vendor patched `std.process.ArgIteratorWindows` to return WTF-16
3. avoid `@memcpy`/`@memmove`
4. never free memory
5. only allocate with `Allocator.allocSentinel`

[1] Windows paths are WTF-16. Most interfaces use WTF-8 for lossless conversion. If we're fine being off the happy path then we can avoid that and use WTF-16 directly.

[2] Zig's iterator for Windows command line returns WTF-8 which we don't want due to [1].

[3] When `@memcpy` and `@memmove` aren't inlined they bring in extra data (~4KiB in `.rdata` and ~1KiB in `.text`).

[4] Short applications can (ab)use the OS as a garbage collector.

[5] Alloc functions will not be inlined if used enough. In this case using different alloc functions has more binary overhead than only using one. `Allocator.allocSentinel` is a better default than `Allocator.alloc`.
