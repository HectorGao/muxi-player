# IINA 1.5.0 dependency runtime for MuxiPlayer

The binary runtime is the **official `iina-1.5.0-release` dependency asset**,
not an arbitrary copy from an installed application. Its build recipe is pinned
to commit `f86d54276547df6d14104583ea604af67433f1e1` of
<https://github.com/iina/deps-buildscripts>. `runtime-lock.json` records the
download URLs and SHA-256 values. The release has 44 dynamic libraries;
mpv is 0.41.0 and FFmpeg is 9.0.1, with GPL features enabled.

This directory contains metadata only. The release also provides the actual
corresponding dependency sources in `MuxiPlayer-<version>-dependencies-source.tar.gz`.
That archive contains:

- the complete upstream build recipes, configuration and patches at that commit;
- all 28 SHA-256-verified source archives from `versions.env`;
- complete libjxl and libplacebo working trees, including recursive submodules
  at the commits recorded in `source-inventory.json` (Git metadata is excluded);
- the unmodified upstream copyright and license documents collected under
  `notices/`, also included in the app's `Contents/Resources/ThirdParty/` directory.

Brotli is provided by libjxl's pinned `third_party/brotli` submodule. Other
vendored sources, including Highway and the OpenGL code generator glad, remain
in their original source trees. Copyright notices within individual source
files remain in those files; the extracted notice collection supplements,
rather than replaces, the complete sources.

## Rebuilding the dependency runtime

Use macOS with Xcode/Command Line Tools and the build tools listed in
`recipes/readme.md` (Meson, Ninja, CMake, pkg-config, automake, autoconf, nasm and
libtool). In a fresh copy of the source archive, run:

```sh
cd recipes
./build.sh arm64
./fix-install-names.sh arm64
```

The archived recipes retain their original behavior, including replacing build
and extracted-source directories. Review them before use, and run them only in
a disposable source/build workspace. MuxiPlayer's collection script does not
execute them. The original downloads are already in `recipes/sources`, and the
two Git working trees include their submodules, so dependency source downloads
are not needed. General build tools and Apple's system SDK are separate
prerequisites, not bundled third-party libraries. The original upstream CI
workflow is included for reference. Exact compiler/SDK reproduction is not
claimed to yield byte-identical Mach-O files.

## License and distribution

Individual components retain their upstream licenses; consult `notices/` and
the original sources. The libmpv/FFmpeg runtime enables GPL code. The combined
MuxiPlayer binary is distributed under the GNU GPL, version 3 or (at your
option) any later version, alongside these component notices. MuxiPlayer's
original source files remain available under their stated MIT license; MIT
does not replace the GPL conditions of the combined binary.

GPL-3.0-or-later is selected for the combined distribution to accommodate the
GPL-2.0-or-later components together with Apache-2.0 dependencies such as
Highway. This does not change the original licenses of individual components.

Every binary release must keep its matching MuxiPlayer source archive and
dependency source archive available alongside the app ZIP, without additional
access restrictions. Do not substitute a Homebrew or installed IINA runtime
under this source claim. A source mismatch or missing source material must
stop release packaging rather than silently falling back to another runtime.

The app ZIP is ad-hoc signed and **not notarized**. It is a development preview,
not an Apple-verified Developer ID distribution. This is independent of the
obligation to provide corresponding source and copyright/license notices.

Official references:

- <https://github.com/iina/deps-buildscripts/releases/tag/iina-1.5.0-release>
- <https://github.com/iina/deps-buildscripts/tree/f86d54276547df6d14104583ea604af67433f1e1>
- <https://github.com/mpv-player/mpv/blob/v0.41.0/Copyright>
- <https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/LICENSE.md>
