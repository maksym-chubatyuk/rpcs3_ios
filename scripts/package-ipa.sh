#!/usr/bin/env bash
# Builds a release of the app as an .ipa for sideloading (AltStore, SideStore, Sideloadly...):
#   scripts/package-ipa.sh 0.1.0        -> build/release/RPCS3-0.1.0.ipa
# Needs what scripts/build-core-ios.sh needs. The app is signed ad hoc, with its entitlements, so
# the sideloading tool can re-sign it with the user's own Apple ID and keep what the app asks for
# (the raised memory limit).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

VERSION="${1:?usage: scripts/package-ipa.sh <version, e.g. 0.1.0>}"
# The build number: commits so far, so every release has a higher one
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
OUT="$BUILD_ROOT/release"
DERIVED="$OUT/derived"
IPA="$OUT/RPCS3-$VERSION.ipa"

echo "== core"
CONFIG=Release "$ROOT/scripts/build-core-ios.sh" > "$LOGS/release-core.log" 2>&1 || { tail -30 "$LOGS/release-core.log"; exit 1; }

echo "== app $VERSION ($BUILD_NUMBER)"
rm -rf "$DERIVED"
if ! xcodebuild -project "$ROOT/app/rpcs3.xcodeproj" -scheme rpcs3 -configuration Release \
    -sdk iphoneos -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build > "$LOGS/release-app.log" 2>&1; then
  grep -E "error:" "$LOGS/release-app.log" | sort -u | head -30
  exit 1
fi

APP="$DERIVED/Build/Products/Release-iphoneos/rpcs3.app"
[[ -f "$APP/Frameworks/RPCS3Core.framework/RPCS3Core" ]] || { echo "The core is missing from the app"; exit 1; }
[[ -d "$APP/PlugIns/rpcs3JITHelper.appex" ]] || { echo "The JIT helper is missing from the app"; exit 1; }

echo "== signing ad hoc"
ENTITLEMENTS="$OUT/entitlements.plist"
cp "$ROOT/app/rpcs3.entitlements" "$ENTITLEMENTS"
# The debugger that enables JIT (StikJIT) needs it; sideloading tools set it too
plutil -replace get-task-allow -bool YES "$ENTITLEMENTS"
# Inside out: frameworks, the extension, then the app
for framework in "$APP"/Frameworks/*.framework "$APP"/PlugIns/*.appex/Frameworks/*.framework; do
  [[ -d "$framework" ]] && codesign --force --sign - --timestamp=none "$framework"
done
codesign --force --sign - --timestamp=none "$APP/PlugIns/rpcs3JITHelper.appex"
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "== packaging"
rm -rf "$OUT/Payload" "$IPA"
mkdir -p "$OUT/Payload"
ditto "$APP" "$OUT/Payload/rpcs3.app"
(cd "$OUT" && zip -qry "$IPA" Payload)
rm -rf "$OUT/Payload"

echo "$IPA ($(du -h "$IPA" | cut -f1)), RPCS3 $(git -C "$RPCS3" rev-parse --short HEAD)"
