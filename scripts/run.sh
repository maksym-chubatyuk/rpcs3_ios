#!/usr/bin/env bash
# Builds the app, installs it on the connected iPhone, starts it and attaches the Mac-side JIT
# host (scripts/jit_host.py), then prints the app's log. The iPhone must be unlocked.
#
#   scripts/run.sh                    build, install, run with JIT
#   SKIP_BUILD=1 scripts/run.sh       run the installed app with JIT
#   POOL_MB=512 scripts/run.sh        size of the JIT pool (default 1024)
#   DEVICE=<id> scripts/run.sh        pick a device (xcrun devicectl list devices)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
DERIVED="$BUILD_ROOT/DerivedData"
APP="$DERIVED/Build/Products/Debug-iphoneos/rpcs3.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$LOGS"

if [[ -z "${DEVICE:-}" ]]; then
  xcrun devicectl list devices --quiet --json-output "$WORK/devices.json" >/dev/null 2>&1 || true
  DEVICE="$(python3 -I -c '
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    if d.get("hardwareProperties", {}).get("platform") == "iOS" and d.get("connectionProperties", {}).get("tunnelState") == "connected":
        print(d["identifier"]); break
' "$WORK/devices.json")"
  [[ -n "$DEVICE" ]] || { echo "No connected iPhone (xcrun devicectl list devices)."; exit 1; }
fi

if [[ -z "${SKIP_BUILD:-}" ]]; then
  if ! xcodebuild -project "$ROOT/app/rpcs3.xcodeproj" -scheme rpcs3 -configuration Debug \
      -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build \
      >"$LOGS/app-build.log" 2>&1; then
    echo "App build failed, see $LOGS/app-build.log"
    grep -E "error:|\*\* BUILD" "$LOGS/app-build.log" | sort -u | head -40
    exit 1
  fi
  echo "app built"
  xcrun devicectl device install app --device "$DEVICE" --quiet "$APP"
  echo "app installed"
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
# Test hook (rpcs3/Emulator.swift): AUTO_FIRMWARE=1 installs Documents/PS3UPDAT.PUP, AUTO_BOOT=<folder in Games>
ENV_JSON="$(python3 -I -c '
import json, os
env = {"RPCS3_JIT_POOL_MB": os.environ.get("POOL_MB", "1024")}
if os.environ.get("AUTO_FIRMWARE"): env["RPCS3_AUTO_FIRMWARE"] = os.environ["AUTO_FIRMWARE"]
if os.environ.get("AUTO_BOOT"): env["RPCS3_AUTO_BOOT"] = os.environ["AUTO_BOOT"]
for name in ("STDERR", "PERF_OVERLAY", "DUMP_AFTER", "SCREENSHOT_EVERY", "PS_AFTER", "SETTINGS_SELFTEST", "AUTO_BOOT_MODE", "BUILD_CACHE", "REMOVE_DATA", "PATCH_TEST"):
    if os.environ.get(name): env["RPCS3_" + name] = os.environ[name]
if os.environ.get("AUTO_BOOT_DELAY"): env["RPCS3_AUTO_BOOT_DELAY"] = os.environ["AUTO_BOOT_DELAY"]
print(json.dumps(env))
')"

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --start-stopped --quiet \
  --environment-variables "$ENV_JSON" --json-output "$WORK/launch.json" "$BUNDLE_ID"
PID="$(plutil -extract result.process.processIdentifier raw -o - "$WORK/launch.json")"
echo "launched pid $PID"

xcrun lldb --batch \
  -o "command script import '$ROOT/scripts/jit_host.py'" \
  -o "jit_host $DEVICE $PID" | tee "$LOGS/jit-host.log"

fetch() {
  xcrun devicectl device copy from --device "$DEVICE" --quiet --timeout 30 \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/$1" --destination "$2" >/dev/null 2>&1
}

sleep "${WAIT:-3}"
if fetch rpcs3-app.log "$LOGS/device-app.log"; then
  echo "--- app log ---"
  cat "$LOGS/device-app.log"
else
  echo "(no app log yet)"
fi
