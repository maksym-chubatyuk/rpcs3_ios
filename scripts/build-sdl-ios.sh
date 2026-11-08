#!/usr/bin/env bash
# Builds RPCS3's pinned SDL3 (3rdparty/libsdl-org/SDL) as a static library for iOS arm64 and
# installs it to build/sdl-ios-install, so RPCS3 and FAudio find it as an installed package.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
SRC="$RPCS3/3rdparty/libsdl-org/SDL"
BUILD="$BUILD_ROOT/sdl-ios"
PREFIX="$BUILD_ROOT/sdl-ios-install"
IOS_MIN="${IOS_MIN:-26.0}"

cmake -G Ninja -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake --build "$BUILD"
cmake --install "$BUILD"
echo "SDL3 for iOS installed to $PREFIX"
