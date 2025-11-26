When learning Zig I went with rewriting dtkit-patch.
Binary size was promising early on so I was interested in how small it could be.
This file is some notes for future (self) reference.

## Size

In particular:

* avoid WTF-8 (Windows)

Using WTF-8 simplifies cross-platform code, but has overhead when converting to WTF-16 for system calls.
We can avoid that if we go off the happy path and use WTF-16 directly.

* use `CommandLineToArgvW` (Windows)

Zig's standard library command line iterator for Windows returns WTF-8.
Instead we use `CommandLineToArgvW` from `shell32.dll`.

* export intrinsics (Windows)

When building for `x86_64-windows-gnu` it looks like when intrinsics (`@memcpy`/`@memset`/`@memmove`) aren't inlined it adds ~5KiB to binary size.
I don't know why re-exporting (implementation is the same) avoids it.
This might be LLVM bitcode?

* turn on GC

Short-lived applications can (ab)use the OS as a garbage collector.

* only allocate with `Allocator.allocSentinel`

Different alloc functions will monomorphize separately.
This can increase binary overhead for each different alloc function used.
I went with `Allocator.allocSentinel` since it's a good default.

* avoid using switch with Zig's error type

Switching on errors can compile to large lookup tables.
As a workaround we use a custom error string lookup to save ~2KiB.
Unfortunately this might define more errors than necessary.

## Linker Map

I learned about linker maps while working on this.
Unfortunately Zig filters for specific options when compiling Zig code.

I got around this by patching `zig.exe` and replacing the string `-dynamicbase:NO` with `/map:linker.map`.
This lets us use `--no-dynamicbase` when building windows executables to dump linker map to `linker.map`.

For example:
`zig build-exe --no-dynamicbase [...]`
