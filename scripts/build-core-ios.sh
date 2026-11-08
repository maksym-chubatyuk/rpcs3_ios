#!/usr/bin/env bash
# Builds the emulator core for iOS arm64: RPCS3 (the rpcs3 submodule, with patches/ applied) with
# our layer (core/) on top, into build/core/ios/RPCS3Core.framework. Needs scripts/build-llvm-ios.sh,
# build-sdl-ios.sh and build-ffmpeg-ios.sh first, and MoltenVK (see README.md).
#   scripts/build-core-ios.sh            configure (if needed) and build
#   RECONFIGURE=1 scripts/build-core-ios.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
BUILD="$BUILD_ROOT/core"
IOS_MIN="${IOS_MIN:-26.0}"
CONFIG="${CONFIG:-Release}"

# MoltenVK for iOS (third_party/MoltenVK, built with its fetchDependencies --ios), linked statically,
# and FFmpeg for iOS (scripts/build-ffmpeg-ios.sh).
MVK="$DOWNLOADS/MoltenVK/Package/Release/MoltenVK"
# Vulkan headers: Khronos' (newer than the copy MoltenVK packages, which lacks driver IDs RPCS3
# uses); MoltenVK's own headers only from its package, copied apart so they do not shadow them.
VK_INC="${VK_INC:-/opt/homebrew/opt/vulkan-headers/include}"
MVK_INC="${MVK_INC:-$BUILD_ROOT/mvk-headers}"
rm -rf "$BUILD_ROOT/mvk-headers" && mkdir -p "$BUILD_ROOT/mvk-headers" && cp -R "$MVK/include/MoltenVK" "$BUILD_ROOT/mvk-headers/"
VK_LIB="${VK_LIB:-$MVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a}"
FFMPEG="${FFMPEG:-$BUILD_ROOT/ffmpeg-ios-install}"

"$ROOT/scripts/apply-patches.sh"

if [[ -n "${RECONFIGURE:-}" || ! -f "$BUILD/build.ninja" ]]; then
  # pkg-config may only see the iOS builds, never the Mac's own libraries
  export PKG_CONFIG_LIBDIR="$FFMPEG/lib/pkgconfig"
  cmake -G Ninja -S "$RPCS3" -B "$BUILD" \
    -DCMAKE_PROJECT_rpcs3_INCLUDE="$ROOT/core/ios.cmake" \
    -DCMAKE_BUILD_TYPE="$CONFIG" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_FIND_ROOT_PATH="$BUILD_ROOT/sdl-ios-install;$BUILD_ROOT/llvm-ios;$FFMPEG" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DLLVM_DIR="$BUILD_ROOT/llvm-ios/lib/cmake/llvm" \
    -DSTATIC_LINK_LLVM=ON \
    -DCMAKE_PREFIX_PATH="$BUILD_ROOT/sdl-ios-install" \
    -DSDL3_DIR="$BUILD_ROOT/sdl-ios-install/lib/cmake/SDL3" \
    -DUSE_VULKAN=ON \
    -DVulkan_INCLUDE_DIR="$VK_INC" \
    -DVulkan_LIBRARY="$VK_LIB" \
    -DCMAKE_CXX_FLAGS="-I$MVK_INC" \
    -DUSE_FAUDIO=ON \
    -DUSE_SDL=ON \
    -DBUILD_RPCS3_TESTS=OFF \
    -DDISABLE_LTO=TRUE -DUSE_LTO=OFF
fi

ninja -C "$BUILD" ${TARGETS:-RPCS3Core}
