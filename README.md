# RPCS3 for iOS

The [RPCS3](https://github.com/RPCS3/rpcs3) PlayStation 3 emulator on iPhone, with its PPU and SPU
LLVM recompilers running natively on arm64.

Needs iOS 26 or later and JIT, which on iOS needs a debugger to attach once per launch. The app does
that itself (below), or StikDebug can, or a Mac during development (`scripts/run.sh`).

## JIT without a Mac

1. Get this iPhone's pairing file (a `.plist` made by iloader, or the pairing tool StikDebug's
   guide uses) onto the phone, and in RPCS3 tap **Import Pairing File…**. It is kept in the
   Keychain. A file copied into the app's folder as `pairingFile.plist` is picked up too.
2. Connect LocalDevVPN. It works on Wi-Fi or
   with no network, but not over cellular data.
3. Open RPCS3. It enables JIT by itself at launch, or tap **Enable JIT**. The first time, the
   Developer Disk Image is downloaded and mounted, which takes a while.

The app starts its own app extension (`rpcs3JITHelper`). A process cannot debug itself, so the
extension attaches StikJIT's debugger to the app through the VPN's loopback tunnel and runs StikJIT's
universal script. That script answers the app's requests the way `scripts/jit_host.py` does from a Mac.

## How JIT works here

On iOS 26 (TXM) an app cannot make memory executable itself. A debugger can: it allocates a region in
the app and writes into each of its 16 KiB pages, after which those pages may run code. The app asks
for one large region at launch (`brk #0xf00d`, `x16 = 1`, the protocol StikDebug's universal script
speaks), maps a second writable view of the same memory with `vm_remap`, checks that code written
through it runs, and lets the debugger go. That region is all the executable memory the app gets.

RPCS3 normally makes executable memory wherever it needs it. On iOS all of it comes from that one
pool instead (`core/include/ios/jit_pool.hpp`, used by `patches/0002` to `0005`):

- the pool is split into fixed parts: asmjit's global runtime (never reset), `jit_runtime` code, and
  LLVM code, with data in a normal RW area next to the pool, within ADRP range;
- code is written through the writable view: asmjit relocates to the executable address and copies
  to the alias; LLVM's RuntimeDyld writes sections into the alias and is told their executable
  addresses with `mapSectionAddress`, so relocations are resolved for where the code runs;
- code RPCS3 patches later (SPU branch patchpoints, dispatcher trees) is written through the alias;
- the pool is reused when a game stops.

Static initializers in the core already generate code, so the core is a separate framework
(`RPCS3Core.framework`) that the app loads with `dlopen` only once it holds the pool.

The core reserves 24 GiB of address space instead of 56 GiB (the 32 GiB "hook" region is unused),
so it fits the 63 GiB map every app gets, including apps signed with a free Apple ID.

## How the repository is built around RPCS3

RPCS3 is included unchanged, as the `rpcs3` submodule pinned to an upstream commit. Everything for
iOS sits next to it:

| Path | What it is |
| --- | --- |
| `rpcs3/` | RPCS3 itself (submodule). Never edited: the build applies `patches/` to it |
| `core/` | Our layer over RPCS3: the bridge to the app (`rpcs3_ios.mm`, built as `RPCS3Core.framework`), the JIT pool and its LLVM memory manager, iOS compatibility, and the CMake glue |
| `patches/` | The few changes RPCS3's code still needs (JIT, memory setup, SDK guards), one topic per file, plus `patches/submodules/<path>.patch` for RPCS3's own submodules |
| `app/` | The Xcode project: the SwiftUI app (library, game view, on-screen controller, JIT setup) and `rpcs3JITHelper`, the extension that enables JIT without a Mac |
| `scripts/` | Builds of the dependencies and the core, running on a phone from a Mac, and updating RPCS3 |
| `third_party/StikJIT/` | StikJIT (MPL-2.0), prebuilt, with its licenses. MoltenVK and FFmpeg sources are downloaded next to it (not tracked) |
| `build/`, `logs/` | Outputs (not tracked) |

The layer touches RPCS3 from outside wherever it can:

- `core/ios.cmake` is passed to RPCS3's CMake as `CMAKE_PROJECT_rpcs3_INCLUDE`. It runs right after
  RPCS3's `project()` call and sets up the iOS build (options, the compatibility header, include
  paths). `core/targets.cmake` runs at the end of RPCS3's configuration and adds our sources and the
  framework to RPCS3's targets.
- The bridge fixes settings at run time instead of RPCS3's defaults: audio through FAudio, the
  shader recompiler without the interpreter, the on-screen controller as player 1, and the bundled
  overlay icons.
- What the app shows from RPCS3's desktop frontend is generated from its Qt sources, never edited
  there: the home menu texts (`scripts/gen-ios-strings.py`) and the settings layout, with desktop's
  tabs, groups, labels and descriptions (`scripts/gen-settings-layout.py`). The settings' values,
  choices and ranges come from RPCS3's configuration at run time (`core/settings.cpp`).

What cannot be done from outside is in `patches/`. Each patch starts with a note on what it does.
Patches marked "Candidate for upstream" fix things that are not specific to this port; once RPCS3
has them, they can be deleted here.

## Building

Needs Xcode, CMake, Ninja, and the Khronos Vulkan headers (`brew install cmake ninja vulkan-headers`).

```sh
git submodule update --init --recursive   # RPCS3 and its own submodules
scripts/build-llvm-ios.sh      # LLVM (RPCS3's pinned version), static, iOS arm64
scripts/build-sdl-ios.sh       # SDL3
scripts/build-ffmpeg-ios.sh    # FFmpeg with RPCS3's component selection
# MoltenVK: clone it into third_party/MoltenVK at RPCS3's pinned commit, run
# ./fetchDependencies --ios, then build the "MoltenVK Package (iOS only)" scheme
scripts/build-core-ios.sh      # applies patches/, builds build/core/ios/RPCS3Core.framework
scripts/run.sh                 # builds the app, installs it on the connected iPhone, runs it with JIT
```

Put the PS3 firmware (`PS3UPDAT.PUP`, from Sony) and your own game dumps on the phone: install the
firmware from the app, and copy game folders or ISOs into the app's `Games` folder in the Files app.

## Settings

The gear in the library opens the global settings, organised like RPCS3's desktop settings dialog,
with search. Swipe a game to the right (or long-press it) for that game's own settings: each one
follows the global settings until it is changed for that game, and can be set back to follow them.
They are RPCS3's custom configs (`custom_configs/config_<title ID>.yml`), holding only what the game
changes.

## Updating RPCS3

```sh
scripts/update-rpcs3.sh            # the latest upstream master (or give a commit or tag)
git add rpcs3 && git commit -m "Update RPCS3"
```

The script moves the submodule, applies `patches/`, regenerates the tables taken from RPCS3, and
builds the core. If upstream changed the lines a patch touches, it stops and names that patch: update
the patch (apply what still fits, fix the rest by hand in `rpcs3/`, then
`git -C rpcs3 diff -- <files>` into the patch file, below its note) and run it again.

## License

GPL-2.0, like RPCS3 (see `LICENSE`). StikJIT is MPL-2.0 and contains idevice (MIT); see
`third_party/StikJIT`.
