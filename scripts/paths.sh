# Sourced by the scripts: where things are.
#   rpcs3/        RPCS3, a git submodule (upstream, never edited; patches/ are applied at build time)
#   build/ logs/  outputs, not tracked
#   third_party/  StikJIT (tracked) and downloaded sources (MoltenVK, FFmpeg; not tracked)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPCS3="$ROOT/rpcs3"
BUILD_ROOT="$ROOT/build"
LOGS="$ROOT/logs"
DOWNLOADS="$ROOT/third_party"
mkdir -p "$BUILD_ROOT" "$LOGS" "$DOWNLOADS"
