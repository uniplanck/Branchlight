#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Branchlight.xcodeproj"
SCHEME="Branchlight"
APP_PATH="${1:-/Applications/Branchlight.app}"

echo "== Generated build settings =="
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -showBuildSettings 2>/dev/null \
  | grep -E "^[[:space:]]*(DEVELOPMENT_TEAM|CODE_SIGN_STYLE|REGISTER_APP_GROUPS|CODE_SIGN_ENTITLEMENTS)[[:space:]]*=" \
  | sort -u || true

if [[ ! -d "$APP_PATH" ]]; then
  echo
  echo "App not found at: $APP_PATH"
  echo "Build/copy the signed app first, or pass its path as the first argument."
  exit 66
fi

HOST="$APP_PATH"
EXT="$APP_PATH/Contents/PlugIns/BranchlightFinderExtension.appex"
XPC="$APP_PATH/Contents/XPCServices/BranchlightGitService.xpc"

XPC_FRAMEWORK="$XPC/Contents/Frameworks/BranchlightCore.framework"

for item in "$HOST" "$EXT" "$XPC"; do
  echo
  echo "== $item =="
  codesign --verify --strict --verbose=1 "$item"
  codesign -dvvv "$item" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Authority)=" || true
  codesign -d --entitlements :- "$item" 2>/dev/null || true
done

echo
echo "== Git XPC runtime framework =="
if [[ -d "$XPC_FRAMEWORK" ]]; then
  echo "FOUND: $XPC_FRAMEWORK"
  otool -L "$XPC/Contents/MacOS/BranchlightGitService" 2>/dev/null || true
else
  echo "MISSING: $XPC_FRAMEWORK"
fi

echo
echo "== PlugInKit Finder registration =="
pluginkit -m -A -D -vvv -i com.uniplanck.Branchlight.Extension || true
