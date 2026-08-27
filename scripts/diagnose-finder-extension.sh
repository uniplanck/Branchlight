#!/bin/bash
set -euo pipefail

APP_PATH="${BRANCHLIGHT_APP_PATH:-/Applications/Branchlight.app}"
EXTENSION_ID="${BRANCHLIGHT_FINDER_EXTENSION_ID:-com.uniplanck.Branchlight.Extension}"
APPEX_PATH="$APP_PATH/Contents/PlugIns/BranchlightFinderExtension.appex"
MODE="${1:---check}"

if [[ "$MODE" != "--check" && "$MODE" != "--repair" ]]; then
  echo "usage: bash scripts/diagnose-finder-extension.sh [--check|--repair]" >&2
  exit 64
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

echo "Branchlight Finder Extension diagnostic"
echo "App: $APP_PATH"
echo "Extension ID: $EXTENSION_ID"
echo

[[ -d "$APP_PATH" ]] || fail "Branchlight.app is not installed at $APP_PATH. Build the signed app, copy it to /Applications, launch it once, then run this script again."
pass "host app is installed"

[[ -d "$APPEX_PATH" ]] || fail "embedded Finder extension is missing: $APPEX_PATH"
pass "embedded Finder extension exists"

HOST_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
APPEX_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPEX_PATH/Contents/Info.plist" 2>/dev/null || true)"
EXTENSION_POINT="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$APPEX_PATH/Contents/Info.plist" 2>/dev/null || true)"

[[ -n "$HOST_ID" ]] || fail "host bundle identifier is missing"
[[ "$APPEX_ID" == "$EXTENSION_ID" ]] || fail "unexpected Finder extension bundle identifier: $APPEX_ID"
[[ "$EXTENSION_POINT" == "com.apple.FinderSync" ]] || fail "unexpected extension point: $EXTENSION_POINT"
pass "bundle metadata is valid ($HOST_ID / $APPEX_ID / $EXTENSION_POINT)"

/usr/bin/codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 \
  || fail "host app signature verification failed"
/usr/bin/codesign --verify --strict "$APPEX_PATH" >/dev/null 2>&1 \
  || fail "Finder extension signature verification failed"
pass "host and Finder extension signatures verify"

registered_output="$(/usr/bin/pluginkit -m -A -D -i "$EXTENSION_ID" 2>/dev/null || true)"
if [[ -n "$registered_output" ]]; then
  pass "PlugInKit already knows the Finder extension"
  echo "$registered_output"
else
  echo "NOT REGISTERED: PlugInKit does not currently list $EXTENSION_ID"
fi

if [[ "$MODE" == "--check" ]]; then
  if [[ -z "$registered_output" ]]; then
    echo
    echo "Repair command:"
    echo "  bash scripts/diagnose-finder-extension.sh --repair"
    exit 2
  fi
  echo
  echo "If the extension is disabled, run the repair mode or enable it in System Settings > General > Login Items & Extensions > Finder."
  exit 0
fi

echo
echo "Repairing PlugInKit registration..."
/usr/bin/pluginkit -a "$APPEX_PATH"
/usr/bin/pluginkit -e use -i "$EXTENSION_ID"
/usr/bin/killall Finder 2>/dev/null || true
sleep 1

registered_output="$(/usr/bin/pluginkit -m -A -D -i "$EXTENSION_ID" 2>/dev/null || true)"
[[ -n "$registered_output" ]] || fail "PlugInKit still does not list the extension after explicit registration"
pass "Finder extension registered and requested for use"
echo "$registered_output"

echo
if [[ "$registered_output" == *"!"* ]]; then
  echo "WARNING: PlugInKit reports a problem marker. Re-check signing/App Group configuration and macOS logs."
fi

echo "Finder was restarted. Re-open System Settings > General > Login Items & Extensions > Finder and verify Branchlight Finder Extension is enabled."
