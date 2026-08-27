#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-/Applications/Branchlight.app}"
FAIL=0
PENDING=0

pass() { printf "PASS    %s\n" "$1"; }
fail() { printf "FAIL    %s\n" "$1"; FAIL=$((FAIL + 1)); }
pending_item() { printf "PENDING %s\n" "$1"; }
pending_workstream() { printf "PENDING-WORKSTREAM %s\n" "$1"; PENDING=$((PENDING + 1)); }

echo "Branchlight Final Acceptance Doctor"
echo "App: $APP"
echo

cd "$ROOT"

if bash scripts/verify-accessibility-contract.sh >/dev/null 2>&1; then
  pass "Accessibility source contract"
else
  fail "Accessibility source contract"
fi

if [[ -d "$APP" ]] && codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  pass "Installed app signature structure"
else
  fail "Installed app signature structure"
fi

EXT="$APP/Contents/PlugIns/BranchlightFinderExtension.appex"
XPC="$APP/Contents/XPCServices/BranchlightGitService.xpc"
XPC_CORE="$XPC/Contents/Frameworks/BranchlightCore.framework"

[[ -d "$EXT" ]] && pass "Finder Extension embedded" || fail "Finder Extension embedded"
[[ -d "$XPC" ]] && pass "Git XPC service embedded" || fail "Git XPC service embedded"
[[ -d "$XPC_CORE" ]] && pass "Git XPC runtime framework embedded" || fail "Git XPC runtime framework embedded"

if [[ -x "$XPC/Contents/MacOS/BranchlightGitService" ]] && \
   otool -l "$XPC/Contents/MacOS/BranchlightGitService" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
  pass "Git XPC self-contained runpath"
else
  fail "Git XPC self-contained runpath"
fi

RELEASE_PENDING=0
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  pass "Developer ID Application identity installed"
else
  pending_item "Developer ID Application identity not installed"
  RELEASE_PENDING=1
fi

PROFILE="${BRANCHLIGHT_NOTARY_KEYCHAIN_PROFILE:-}"
if [[ -n "$PROFILE" ]]; then
  pass "Notary Keychain profile configured in environment: $PROFILE"
else
  pending_item "BRANCHLIGHT_NOTARY_KEYCHAIN_PROFILE is not set"
  RELEASE_PENDING=1
fi

if [[ "$RELEASE_PENDING" -eq 1 ]]; then
  pending_workstream "Release signing / notarization"
else
  pass "Release signing / notarization prerequisites"
fi

OAUTH_FILE="$ROOT/Config/Branchlight.oauth.local.xcconfig"
OAUTH_ID=""
if [[ -f "$OAUTH_FILE" ]]; then
  OAUTH_ID="$(sed -n 's/^[[:space:]]*BRANCHLIGHT_GITHUB_CLIENT_ID[[:space:]]*=[[:space:]]*//p' "$OAUTH_FILE" | head -n 1 | tr -d '[:space:]')"
fi
OAUTH_PENDING=0
if [[ -n "$OAUTH_ID" ]]; then
  pass "GitHub OAuth Client ID configured locally"
else
  pending_item "GitHub OAuth Client ID is not configured"
  OAUTH_PENDING=1
fi

EMBEDDED_OAUTH=""
if [[ -f "$APP/Contents/Info.plist" ]]; then
  EMBEDDED_OAUTH="$(/usr/libexec/PlistBuddy -c "Print :BranchlightGitHubClientID" "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$EMBEDDED_OAUTH" ]]; then
    pass "Installed app contains GitHub OAuth Client ID"
  else
    pending_item "Installed app does not yet contain GitHub OAuth Client ID"
    OAUTH_PENDING=1
  fi
fi

if [[ "$OAUTH_PENDING" -eq 1 ]]; then
  pending_workstream "GitHub OAuth"
else
  pass "GitHub OAuth configuration"
fi

VOICEOVER_ACCEPTANCE="$ROOT/.branchlight-local-acceptance/voiceover.accepted"
if [[ -f "$VOICEOVER_ACCEPTANCE" ]]; then
  pass "VoiceOver real-Mac acceptance recorded"
else
  pending_item "VoiceOver real-Mac navigation acceptance must be performed manually once"
  pending_workstream "VoiceOver real-Mac acceptance"
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "FINAL_ACCEPTANCE_FAIL fail=$FAIL pending=$PENDING"
  exit 1
fi
if [[ "$PENDING" -gt 0 ]]; then
  echo "FINAL_ACCEPTANCE_PENDING pending=$PENDING"
  exit 2
fi
echo "FINAL_ACCEPTANCE_AUTOMATED_PASS"
