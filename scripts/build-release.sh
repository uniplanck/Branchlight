#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Branchlight.xcodeproj"
SCHEME="Branchlight"
CONFIGURATION="Release"
MODE="${1:---unsigned}"
OUTPUT_DIR="${BRANCHLIGHT_RELEASE_OUTPUT_DIR:-$ROOT/.release-output}"

if [[ "$MODE" != "--unsigned" && "$MODE" != "--signed" ]]; then
  echo "usage: bash scripts/build-release.sh [--unsigned|--signed]" >&2
  exit 64
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required so release builds are generated from project.yml. Install xcodegen before building a Branchlight release." >&2
  exit 69
fi

(
  cd "$ROOT"
  xcodegen generate
)

HOST_PLIST="$ROOT/BranchlightHost/Info.plist"
EXTENSION_PLIST="$ROOT/BranchlightFinderExtension/Info.plist"
XPC_PLIST="$ROOT/BranchlightXPC/Info.plist"
HOST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOST_PLIST")"
HOST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$HOST_PLIST")"
EXT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXTENSION_PLIST")"
EXT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXTENSION_PLIST")"
XPC_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$XPC_PLIST")"
XPC_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$XPC_PLIST")"

if [[ "$HOST_VERSION" != "$EXT_VERSION" || "$HOST_BUILD" != "$EXT_BUILD" ]]; then
  echo "Host/Finder Extension version mismatch: host=$HOST_VERSION($HOST_BUILD) extension=$EXT_VERSION($EXT_BUILD)" >&2
  exit 65
fi
if [[ "$HOST_VERSION" != "$XPC_VERSION" || "$HOST_BUILD" != "$XPC_BUILD" ]]; then
  echo "Host/Git XPC version mismatch: host=$HOST_VERSION($HOST_BUILD) xpc=$XPC_VERSION($XPC_BUILD)" >&2
  exit 65
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/BranchlightRelease.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

DERIVED_DATA="$WORK_DIR/DerivedData"
ARCHIVE_PATH="$WORK_DIR/Branchlight.xcarchive"
APP_PATH=""

verify_bundle() {
  local app="$1"
  local extension="$app/Contents/PlugIns/BranchlightFinderExtension.appex"
  local xpc="$app/Contents/XPCServices/BranchlightGitService.xpc"
  local framework="$app/Contents/Frameworks/BranchlightCore.framework"
  local xpc_framework="$xpc/Contents/Frameworks/BranchlightCore.framework"

  test -d "$app"
  test -x "$app/Contents/MacOS/Branchlight"
  test -d "$extension"
  test -x "$extension/Contents/MacOS/BranchlightFinderExtension"
  test -d "$xpc"
  test -x "$xpc/Contents/MacOS/BranchlightGitService"
  test -d "$framework"
  test -f "$framework/BranchlightCore"
  test -d "$xpc_framework"
  test -f "$xpc_framework/BranchlightCore"

  local host_version host_build extension_version extension_build extension_point
  local xpc_version xpc_build xpc_service_type
  host_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  host_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  extension_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension/Contents/Info.plist")"
  extension_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extension/Contents/Info.plist")"
  extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$extension/Contents/Info.plist")"
  xpc_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$xpc/Contents/Info.plist")"
  xpc_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$xpc/Contents/Info.plist")"
  xpc_service_type="$(/usr/libexec/PlistBuddy -c 'Print :XPCService:ServiceType' "$xpc/Contents/Info.plist")"

  test "$host_version" = "$HOST_VERSION"
  test "$host_build" = "$HOST_BUILD"
  test "$extension_version" = "$HOST_VERSION"
  test "$extension_build" = "$HOST_BUILD"
  test "$extension_point" = "com.apple.FinderSync"
  test "$xpc_version" = "$HOST_VERSION"
  test "$xpc_build" = "$HOST_BUILD"
  test "$xpc_service_type" = "Application"
}

create_dmg() {
  local app="$1"
  local dmg="$2"
  rm -f "$dmg"
  hdiutil create \
    -volname "Branchlight" \
    -srcfolder "$app" \
    -ov \
    -format UDZO \
    "$dmg"
  hdiutil verify "$dmg"
}

if [[ "$MODE" == "--unsigned" ]]; then
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build

  APP_PATH="$DERIVED_DATA/Build/Products/Release/Branchlight.app"
  verify_bundle "$APP_PATH"
  create_dmg "$APP_PATH" "$WORK_DIR/Branchlight-unsigned-readiness.dmg"
  echo "Unsigned Release readiness PASS: Branchlight $HOST_VERSION ($HOST_BUILD) + Finder Sync + Git XPC + DMG"
  exit 0
fi

: "${BRANCHLIGHT_DEVELOPMENT_TEAM:?Set BRANCHLIGHT_DEVELOPMENT_TEAM for signed release builds}"
CODE_SIGN_IDENTITY="${BRANCHLIGHT_CODE_SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${BRANCHLIGHT_NOTARY_KEYCHAIN_PROFILE:-}"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$BRANCHLIGHT_DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  COMPILER_INDEX_STORE_ENABLE=NO \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/Branchlight.app"
verify_bundle "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH/Contents/PlugIns/BranchlightFinderExtension.appex"
codesign --verify --deep --strict --verbose=2 "$APP_PATH/Contents/XPCServices/BranchlightGitService.xpc"

if ! codesign -d --verbose=4 "$APP_PATH" 2>&1 | grep -q 'runtime'; then
  echo "Signed host app is missing Hardened Runtime." >&2
  exit 66
fi
if ! codesign -d --verbose=4 "$APP_PATH/Contents/PlugIns/BranchlightFinderExtension.appex" 2>&1 | grep -q 'runtime'; then
  echo "Signed Finder Extension is missing Hardened Runtime." >&2
  exit 67
fi
if ! codesign -d --verbose=4 "$APP_PATH/Contents/XPCServices/BranchlightGitService.xpc" 2>&1 | grep -q 'runtime'; then
  echo "Signed Git XPC service is missing Hardened Runtime." >&2
  exit 68
fi

mkdir -p "$OUTPUT_DIR"
ARTIFACT_BASENAME="Branchlight-${HOST_VERSION}-build-${HOST_BUILD}-macOS"
ZIP_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.dmg"
ZIP_CHECKSUM_PATH="$ZIP_PATH.sha256"
DMG_CHECKSUM_PATH="$DMG_PATH.sha256"

rm -f "$ZIP_PATH" "$DMG_PATH" "$ZIP_CHECKSUM_PATH" "$DMG_CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"

  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
else
  echo "App notarization skipped: BRANCHLIGHT_NOTARY_KEYCHAIN_PROFILE is not set." >&2
fi

create_dmg "$APP_PATH" "$DMG_PATH"
codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
else
  echo "DMG notarization skipped: BRANCHLIGHT_NOTARY_KEYCHAIN_PROFILE is not set." >&2
fi

shasum -a 256 "$ZIP_PATH" > "$ZIP_CHECKSUM_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_CHECKSUM_PATH"

echo "Release ZIP: $ZIP_PATH"
echo "ZIP SHA-256: $(cat "$ZIP_CHECKSUM_PATH")"
echo "Release DMG: $DMG_PATH"
echo "DMG SHA-256: $(cat "$DMG_CHECKSUM_PATH")"
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "SIGNED_NOT_NOTARIZED"
else
  echo "SIGNED_NOTARIZED_STAPLED"
fi
