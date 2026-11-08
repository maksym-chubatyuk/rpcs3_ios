#!/usr/bin/env bash
# Builds FFmpeg for iOS arm64 as static libraries, with the same components RPCS3's own
# prebuilts enable (3rdparty/ffmpeg/ffmpeg.patch). The version matches the headers RPCS3 ships
# (3rdparty/ffmpeg/include/libavutil/ffversion.h). Output: build/ffmpeg-ios-install.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
VERSION="${FFMPEG_VERSION:-8.1.1}"
SRC="$DOWNLOADS/ffmpeg-$VERSION"
BUILD="$BUILD_ROOT/ffmpeg-ios"
PREFIX="$BUILD_ROOT/ffmpeg-ios-install"
IOS_MIN="${IOS_MIN:-26.0}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

if [[ ! -x "$SRC/configure" ]]; then
  mkdir -p "$DOWNLOADS"
  curl -fL --retry 3 -o "$DOWNLOADS/ffmpeg-$VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  tar -xJf "$DOWNLOADS/ffmpeg-$VERSION.tar.xz" -C "$DOWNLOADS"
fi

# Same selection as RPCS3's ffmpeg.patch
COMPONENTS=(
  --disable-everything --disable-network
  --enable-decoder=aac --enable-decoder=aac_latm --enable-decoder=atrac3 --enable-decoder=atrac3p
  --enable-decoder=atrac9 --enable-decoder=mp3 --enable-decoder=pcm_s16le --enable-decoder=pcm_s8
  --enable-decoder=h264 --enable-decoder=mpeg4 --enable-decoder=mpeg2video --enable-decoder=mjpeg --enable-decoder=mjpegb
  --enable-encoder=pcm_s16le --enable-encoder=ac3 --enable-encoder=aac
  --enable-encoder=ffv1 --enable-encoder=mpeg4 --enable-encoder=mjpeg
  --enable-muxer=avi --enable-muxer=h264 --enable-muxer=mjpeg --enable-muxer=mp4
  --enable-demuxer=h264 --enable-demuxer=m4v --enable-demuxer=mp3 --enable-demuxer=mpegvideo --enable-demuxer=mpegps
  --enable-demuxer=mjpeg --enable-demuxer=mov --enable-demuxer=avi --enable-demuxer=aac --enable-demuxer=pmp
  --enable-demuxer=oma --enable-demuxer=pcm_s16le --enable-demuxer=pcm_s8 --enable-demuxer=wav
  --enable-parser=h264 --enable-parser=mpeg4video --enable-parser=mpegaudio --enable-parser=mpegvideo
  --enable-parser=mjpeg --enable-parser=aac --enable-parser=aac_latm
  --enable-protocol=file
  --enable-bsf=mjpeg2jpeg
)

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"
"$SRC/configure" \
  --prefix="$PREFIX" \
  --enable-cross-compile --target-os=darwin --arch=aarch64 \
  --cc="$(xcrun --sdk iphoneos -f clang)" \
  --sysroot="$SDK" \
  --extra-cflags="-arch arm64 -miphoneos-version-min=$IOS_MIN" \
  --extra-ldflags="-arch arm64 -miphoneos-version-min=$IOS_MIN" \
  --enable-static --disable-shared --enable-pic \
  --disable-doc --disable-programs --disable-debug \
  --enable-runtime-cpudetect --disable-autodetect \
  --disable-openssl --disable-schannel \
  "${COMPONENTS[@]}"
make -j"$(sysctl -n hw.ncpu)"
make install
echo "FFmpeg $VERSION for iOS installed to $PREFIX"
