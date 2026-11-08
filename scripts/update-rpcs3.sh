#!/usr/bin/env bash
# Moves the rpcs3 submodule to another upstream commit (default: the latest master), then applies
# our patches, regenerates the tables taken from RPCS3, and builds the core.
#   scripts/update-rpcs3.sh            latest upstream master
#   scripts/update-rpcs3.sh <commit>   a given commit or tag
# If it all works, commit the new submodule pointer: git add rpcs3 && git commit -m "Update RPCS3"
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
TARGET="${1:-origin/master}"

# Drop the applied patches (the tree is upstream plus patches/, nothing else is kept there)
git -C "$RPCS3" submodule foreach --quiet 'git checkout -q -- . && git clean -qfd'
git -C "$RPCS3" checkout -q -- . && git -C "$RPCS3" clean -qfd

git -C "$RPCS3" fetch -q origin
git -C "$RPCS3" checkout -q --detach "$TARGET"
git -C "$RPCS3" submodule update --init --recursive -q
echo "rpcs3 is now at $(git -C "$RPCS3" log -1 --format='%h %s')"

"$ROOT/scripts/apply-patches.sh"
python3 -I "$ROOT/scripts/gen-ios-strings.py"
"$ROOT/scripts/build-core-ios.sh"
