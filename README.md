# RPCS3 for iOS

The [RPCS3](https://github.com/RPCS3/rpcs3) PlayStation 3 emulator on iPhone, with its LLVM
recompilers running natively. Needs iOS 26 or later; tested on an iPhone 16 Pro Max.

## Installing

You need [iloader](https://github.com/nab138/iloader) on a computer and
[LocalDevVPN](https://apps.apple.com/app/id6755608044) on the iPhone.

1. Install the IPA from [Releases](https://github.com/maksym-chubatyuk/rpcs3_ios/releases) with
   iloader (a free Apple ID works; reinstall every 7 days).
2. Make the pairing file in iloader, get it onto the phone, and tap **Import Pairing File…** in RPCS3 (once).
3. Connect LocalDevVPN and open RPCS3: it enables JIT by itself (needed every launch).
4. Install the firmware ([PS3UPDAT.PUP](https://www.playstation.com/support/hardware/ps3/system-software/))
   and add your own games with **+**: folders, ISOs, or PKG files with their `.rap` licences.

How well a game runs follows [RPCS3's compatibility list](https://rpcs3.net/compatibility), within
what a phone's GPU and memory allow.

## Features

- RPCS3's settings, globally and per game, laid out like desktop's.
- Per game: patches (with rpcs3.net downloads), controls, savestates, caches, save data and trophies.
- Controller mapping for seven players, and on-screen controls you can rearrange.
- Users, save data (import/export through Files), trophies, and RPCN online play.
- Logs to view and share.

## Reporting problems

[Open an issue](https://github.com/maksym-chubatyuk/rpcs3_ios/issues/new/choose) with RPCS3.log
(Settings › Logs › Share; after a crash, the **Previous** log). Please don't report iOS problems
to RPCS3's own tracker.

## Development

**JIT.** On iOS 26 an app can't make memory executable; a debugger can. At launch the app asks the
debugger for one large region (`brk #0xf00d`, StikDebug's protocol), maps a writable alias of it,
and all of RPCS3's generated code lives in that pool (`core/include/ios/jit_pool.hpp`). The debugger
is StikJIT, run by the app's own extension (`rpcs3JITHelper`) through LocalDevVPN, or a Mac
(`scripts/run.sh`). The core is a separate framework, loaded with `dlopen` once the pool exists.

**Layout.** RPCS3 is an unmodified submodule; everything for iOS sits beside it.

| Path | |
| --- | --- |
| `rpcs3/` | RPCS3 (submodule, never edited) |
| `core/` | Our layer: the C API for the app (`rpcs3_ios.h`), one file per feature, the JIT pool, CMake glue |
| `patches/` | The few changes RPCS3 still needs, applied at build time, each with a note |
| `app/` | The SwiftUI app and the JIT helper extension |
| `scripts/` | Builds, running on a phone, packaging, updating RPCS3 |
| `third_party/StikJIT/` | StikJIT (MPL-2.0), prebuilt |

The build hooks into RPCS3's CMake from outside (`core/ios.cmake`, `core/targets.cmake`); the
settings layout and home menu texts are generated from RPCS3's Qt sources.

**Building** (Xcode, `brew install cmake ninja vulkan-headers`):

```sh
git submodule update --init --recursive
scripts/build-llvm-ios.sh && scripts/build-sdl-ios.sh && scripts/build-ffmpeg-ios.sh
# MoltenVK: clone into third_party/MoltenVK at RPCS3's pinned commit, ./fetchDependencies --ios,
# then build the "MoltenVK Package (iOS only)" scheme
scripts/build-core-ios.sh          # build/core/ios/RPCS3Core.framework
scripts/run.sh                     # build, install and run on the connected iPhone, with JIT
```

**Releasing:** `scripts/package-ipa.sh 0.2.0`, then
`gh release create v0.2.0 build/release/RPCS3-0.2.0.ipa`.

**Updating RPCS3:** `scripts/update-rpcs3.sh` (latest master, or a commit or tag), then commit the
submodule. If a patch no longer applies, it stops and names it; fix it in `rpcs3/` and save
`git -C rpcs3 diff` into the patch.

What has to be tested by hand is in [TESTING.md](TESTING.md). The app icon is made from RPCS3's
logo with `swift scripts/gen-app-icon.swift`.

## License

GPL-2.0, like RPCS3 (`LICENSE`). StikJIT is MPL-2.0 and contains idevice (MIT); see `third_party/StikJIT`.
