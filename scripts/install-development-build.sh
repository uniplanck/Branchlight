#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/development-derived-data"
APP="$DERIVED_DATA/Build/Products/Debug/Branchlight.app"
APPLICATIONS_APP="/Applications/Branchlight.app"
EXTENSION_ID="com.uniplanck.Branchlight.Extension"
BACKUP_DIR="$HOME/Library/Caches/com.uniplanck.Branchlight/DevelopmentBackups"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required." >&2
  exit 69
fi

echo "== Configure signing =="
bash scripts/configure-development-signing.sh

echo
echo "== Generate Xcode project =="
xcodegen generate

echo
echo "== Build signed Debug app =="
rm -rf "$DERIVED_DATA"
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build

HOST="$APP"
EXT="$APP/Contents/PlugIns/BranchlightFinderExtension.appex"
XPC="$APP/Contents/XPCServices/BranchlightGitService.xpc"
XPC_CORE="$XPC/Contents/Frameworks/BranchlightCore.framework"
XPC_BIN="$XPC/Contents/MacOS/BranchlightGitService"

echo
echo "== Verify bundle structure =="
test -d "$HOST"
test -d "$EXT"
test -d "$XPC"
test -d "$XPC_CORE"
test -x "$XPC_BIN"
otool -L "$XPC_BIN" | grep -q "@rpath/BranchlightCore.framework"
otool -l "$XPC_BIN" | grep -q "@executable_path/../Frameworks"
codesign --verify --deep --strict "$HOST"
codesign --verify --strict "$EXT"
codesign --verify --strict "$XPC"
echo "Bundle verification PASS"

echo
echo "== Install development app =="
pkill -x Branchlight 2>/dev/null || true
if [[ -d "$APPLICATIONS_APP/Contents/PlugIns/BranchlightFinderExtension.appex" ]]; then
  pluginkit -r "$APPLICATIONS_APP/Contents/PlugIns/BranchlightFinderExtension.appex" 2>/dev/null || true
fi

if [[ -d "$APPLICATIONS_APP" ]]; then
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$APPLICATIONS_APP" >/dev/null 2>&1 || true
  fi
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/Branchlight-$(date +%Y%m%d-%H%M%S).bundle-backup"
  mv "$APPLICATIONS_APP" "$BACKUP"
  echo "Previous app backed up outside LaunchServices-visible app locations: $BACKUP"

  mapfile -t OLD_BACKUPS < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'Branchlight-*.bundle-backup' -print | sort -r)
  if [[ "${#OLD_BACKUPS[@]}" -gt 3 ]]; then
    for old in "${OLD_BACKUPS[@]:3}"; do
      rm -rf "$old"
    done
  fi
fi

ditto "$APP" "$APPLICATIONS_APP"
pluginkit -a "$APPLICATIONS_APP/Contents/PlugIns/BranchlightFinderExtension.appex"
pluginkit -e use -i "$EXTENSION_ID"
killall Finder || true

echo
echo "== Installed bundle diagnostics =="
bash scripts/diagnose-development-signing.sh "$APPLICATIONS_APP"

echo
echo "== Prepare Finder acceptance probe =="
rm -f "$ROOT/branchlight-finder-acceptance.tmp"
if [[ ! -e "$ROOT/branchlight-finder-acceptance.txt" ]]; then
  printf "Branchlight Finder acceptance probe\n" > "$ROOT/branchlight-finder-acceptance.txt"
fi
git reset --quiet -- branchlight-finder-acceptance.txt 2>/dev/null || true

open "$APPLICATIONS_APP"
open -R "$ROOT/branchlight-finder-acceptance.txt"

echo
echo "DEVELOPMENT_INSTALL_PASS"
echo "Finder acceptance probe: $ROOT/branchlight-finder-acceptance.txt"
echo "Expected menu before staging: Status: Untracked / Stage Selected"
