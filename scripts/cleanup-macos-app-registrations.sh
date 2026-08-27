#!/bin/bash
set -euo pipefail

APP_NAME="${1:-Branchlight}"
CANONICAL_APP="${2:-/Applications/Branchlight.app}"
HOST_ID="${3:-com.uniplanck.Branchlight}"
EXTENSION_ID="${4:-com.uniplanck.Branchlight.Extension}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "This cleanup is scoped to:"
echo "  App: $APP_NAME"
echo "  Canonical path: $CANONICAL_APP"
echo "  Bundle ID: $HOST_ID"
echo "  Extension ID: $EXTENSION_ID"
echo

declare -a CANDIDATES=()

add_candidate() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  [[ -d "$path" ]] || return 0
  [[ "$path" == "$CANONICAL_APP" ]] && return 0
  CANDIDATES+=("$path")
}

while IFS= read -r path; do
  add_candidate "$path"
done < <(mdfind "kMDItemCFBundleIdentifier == '$HOST_ID'" 2>/dev/null || true)

for root in \
  "$HOME/Library/Developer/Xcode/DerivedData" \
  "$HOME/Library/Caches" \
  "/Applications"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r path; do
    add_candidate "$path"
  done < <(find "$root" -type d -name "$APP_NAME.app" -prune -print 2>/dev/null || true)
done

if [[ "${#CANDIDATES[@]}" -gt 0 ]]; then
  mapfile -t UNIQUE < <(printf "%s\n" "${CANDIDATES[@]}" | awk '!seen[$0]++')
else
  UNIQUE=()
fi

echo "== Non-canonical app registrations found =="
if [[ "${#UNIQUE[@]}" -eq 0 ]]; then
  echo "None"
else
  printf "  %s\n" "${UNIQUE[@]}"
fi

echo
echo "== Unregister non-canonical copies from LaunchServices =="
if [[ -x "$LSREGISTER" ]]; then
  for path in "${UNIQUE[@]}"; do
    "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
    echo "Unregistered: $path"
  done
else
  echo "LaunchServices registration tool not found; skipped."
fi

echo
echo "== Reset TCC only for this app identity =="
tccutil reset All "$HOST_ID" 2>/dev/null || true
tccutil reset All "$EXTENSION_ID" 2>/dev/null || true
echo "Scoped TCC reset complete. Other apps were not reset."

echo
echo "== Re-register canonical app/extension =="
if [[ -d "$CANONICAL_APP" ]]; then
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$CANONICAL_APP" >/dev/null 2>&1 || true
  fi
  EXT="$CANONICAL_APP/Contents/PlugIns/BranchlightFinderExtension.appex"
  if [[ -d "$EXT" ]]; then
    pluginkit -r "$EXT" >/dev/null 2>&1 || true
    pluginkit -a "$EXT"
    pluginkit -e use -i "$EXTENSION_ID"
  fi
else
  echo "Canonical app not found: $CANONICAL_APP" >&2
  exit 66
fi

killall Finder >/dev/null 2>&1 || true
killall "System Settings" >/dev/null 2>&1 || true

echo
echo "REGISTRATION_CLEANUP_PASS"
echo "macOS may ask for this app's permissions once again after the scoped TCC reset."
