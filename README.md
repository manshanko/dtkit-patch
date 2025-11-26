dtkit-patch
===========

Small tool to patch Darktide so mods can be loaded with [Darktide Mod Loader (DML)](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader/).

Based on Aussiemon's original nodejs script.

## About

dtkit-patch patches `bundle_database.data` to load `9ba626afa44a3aa3.patch_999` from DML.

Darktide updating or validating files will restore `bundle_database.data` which requires running dtkit-patch again to enable mods.

## Troubleshooting

dtkit-patch tries to find the Darktide folder automatically which can fail sometimes.
If that happens try:
```
dtkit-patch --toggle <PATH_TO_DARKTIDE>/bundle
```
where `<PATH_TO_DARKTIDE>` is Darktide's install location (e.g. `C:\Program Files (x86)\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\bundle`).

## Build

Download [Zig 0.15](https://ziglang.org/download/#release-0.15.2) and build dtkit-patch with `zig build --release=safe -Dstrip`.
