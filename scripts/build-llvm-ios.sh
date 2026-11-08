#!/usr/bin/env bash
# Cross-builds RPCS3's pinned LLVM (3rdparty/llvm/llvm) as static libraries for iOS arm64.
# Output: build/llvm-ios-install (LLVMConfig.cmake under lib/cmake/llvm).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
SRC="$RPCS3/3rdparty/llvm/llvm/llvm"
BUILD="$BUILD_ROOT/llvm-ios"
PREFIX="$BUILD_ROOT/llvm-ios-install"
IOS_MIN="${IOS_MIN:-26.0}"

HOST="$BUILD_ROOT/llvm-host-tools"
# Host (macOS) tablegen tools, used by the iOS build.
if [[ ! -x "$HOST/bin/llvm-tblgen" ]]; then
  cmake -G Ninja -S "$SRC" -B "$HOST" -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD=AArch64 -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_LIBXML2=OFF
  ninja -C "$HOST" llvm-tblgen llvm-min-tblgen
fi

cmake -G Ninja -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DLLVM_TARGET_ARCH=AArch64 \
  -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios"$IOS_MIN" \
  -DLLVM_HOST_TRIPLE=arm64-apple-ios"$IOS_MIN" \
  -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_BUILD_RUNTIME=OFF -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
  -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_RTTI=OFF \
  -DLLVM_ENABLE_PIC=ON -DLLVM_ENABLE_WARNINGS=OFF \
  -DLLVM_ENABLE_BACKTRACES=OFF -DLLVM_ENABLE_CRASH_OVERRIDES=OFF \
  -DLLVM_ENABLE_PLUGINS=OFF \
  -DLLVM_NATIVE_TOOL_DIR="$HOST/bin" -DLLVM_TABLEGEN="$HOST/bin/llvm-tblgen" -DLLVM_USE_HOST_TOOLS=OFF

# Only the static libraries: executables (tablegen) cannot be built for iOS.
# RPCS3 uses the build tree's LLVMConfig.cmake (build/llvm-ios/lib/cmake/llvm).
LIBS=$(ninja -C "$BUILD" -t targets all | sed -n 's/^\(lib\/libLLVM[A-Za-z0-9]*\.a\):.*/\1/p' | sort -u)
ninja -C "$BUILD" $LIBS
echo "LLVM for iOS built: LLVM_DIR=$BUILD/lib/cmake/llvm"
