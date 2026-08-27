#!/bin/bash
set -euo pipefail

APP_NAME="${1:-Branchlight}"
CANONICAL_APP="${2:-/Applications/$APP_NAME.app}"
HOST_ID="${3:-}"
EXTENSION_ID="${4:-}"
PURGE_NAME_ONLY=0
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "$HOST_ID" && -f "$CANONICAL_APP/Contents/Info.plist" ]]; then
  HOST_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CANONICAL_APP/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ -z "$HOST_ID" ]]; then
  if [[ ! -d "$CANONICAL_APP" ]]; then
    PURGE_NAME_ONLY=1
    echo "Canonical app is not installed at $CANONICAL_APP."
    echo "Falling back to exact Parent Name cleanup for: $APP_NAME"
  else
    echo "Could not determine the canonical app bundle identifier." >&2
    exit 64
  fi
fi

EXTENSION_IDS=()
if [[ -n "$EXTENSION_ID" ]]; then
  EXTENSION_IDS+=("$EXTENSION_ID")
elif [[ "$PURGE_NAME_ONLY" -eq 0 && -d "$CANONICAL_APP/Contents/PlugIns" ]]; then
  while IFS= read -r appex; do
    [[ -f "$appex/Contents/Info.plist" ]] || continue
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex/Contents/Info.plist" 2>/dev/null || true)"
    [[ -n "$id" ]] && EXTENSION_IDS+=("$id")
  done < <(find "$CANONICAL_APP/Contents/PlugIns" -maxdepth 1 -type d -name '*.appex' -print 2>/dev/null || true)
fi

if [[ "$PURGE_NAME_ONLY" -eq 1 ]]; then
  echo "== Exact Parent Name plug-in cleanup =="
  CURRENT_PATH=""
  CURRENT_PARENT=""
  MATCHED_PATHS=()

  while IFS= read -r line; do
    case "$line" in
      *"Path = "*)
        CURRENT_PATH="${line#*Path = }"
        ;;
      *"Parent Name = "*)
        CURRENT_PARENT="${line#*Parent Name = }"
        if [[ "$CURRENT_PARENT" == "$APP_NAME" && -n "$CURRENT_PATH" ]]; then
          MATCHED_PATHS+=("$CURRENT_PATH")
        fi
        ;;
      "")
        CURRENT_PATH=""
        CURRENT_PARENT=""
        ;;
    esac
  done < <(pluginkit -m -A -D -vvv 2>/dev/null || true)

  if [[ "${#MATCHED_PATHS[@]}" -eq 0 ]]; then
    echo "No registered plug-ins found for exact Parent Name: $APP_NAME"
  else
    while IFS= read -r ext; do
      [[ -n "$ext" ]] || continue
      echo "Unregistering: $ext"
      pluginkit -r "$ext" >/dev/null 2>&1 || true
    done < <(printf "%s\n" "${MATCHED_PATHS[@]}" | awk '!seen[$0]++')
  fi

  killall pkd >/dev/null 2>&1 || true
  killall Finder >/dev/null 2>&1 || true
  killall "System Settings" >/dev/null 2>&1 || true
  sleep 2

  echo
  echo "== Remaining exact Parent Name registrations =="
  REMAINING=0
  CURRENT_PATH=""
  CURRENT_PARENT=""
  while IFS= read -r line; do
    case "$line" in
      *"Path = "*) CURRENT_PATH="${line#*Path = }" ;;
      *"Parent Name = "*)
        CURRENT_PARENT="${line#*Parent Name = }"
        if [[ "$CURRENT_PARENT" == "$APP_NAME" && -n "$CURRENT_PATH" ]]; then
          echo "$CURRENT_PATH"
          REMAINING=$((REMAINING + 1))
        fi
        ;;
      "") CURRENT_PATH=""; CURRENT_PARENT="" ;;
    esac
  done < <(pluginkit -m -A -D -vvv 2>/dev/null || true)

  if [[ "$REMAINING" -eq 0 ]]; then
    echo "None"
    echo "REGISTRATION_CLEANUP_PASS name-only"
    exit 0
  fi

  echo "REGISTRATION_CLEANUP_INCOMPLETE remaining=$REMAINING" >&2
  exit 1
fi

echo "This cleanup is scoped to:"
echo "  App: $APP_NAME"
echo "  Canonical path: $CANONICAL_APP"
echo "  Bundle ID: $HOST_ID"
if [[ "${#EXTENSION_IDS[@]}" -gt 0 ]]; then
  printf '  Extension ID: %s\n' "${EXTENSION_IDS[@]}"
else
  echo "  Extension ID: none detected"
fi
echo

declare -a CANDIDATES=()

echo "== LaunchServices bundle registrations =="
LS_REGISTERED_PATHS=()
if [[ -x "$LSREGISTER" && -n "$HOST_ID" ]]; then
  CURRENT_LS_PATH=""
  while IFS= read -r line; do
    case "$line" in
      path:*)
        CURRENT_LS_PATH="${line#path:}"
        CURRENT_LS_PATH="${CURRENT_LS_PATH#"${CURRENT_LS_PATH%%[![:space:]]*}"}"
        CURRENT_LS_PATH="$(printf '%s\n' "$CURRENT_LS_PATH" | sed -E 's/[[:space:]]+\(0x[0-9A-Fa-f]+\)$//')"
        ;;
      identifier:*)
        CURRENT_LS_ID="${line#identifier:}"
        CURRENT_LS_ID="${CURRENT_LS_ID#"${CURRENT_LS_ID%%[![:space:]]*}"}"
        if [[ "$CURRENT_LS_ID" == "$HOST_ID" && -n "$CURRENT_LS_PATH" ]]; then
          LS_REGISTERED_PATHS+=("$CURRENT_LS_PATH")
        fi
        ;;
      -------------------------------------------------------------------------------*)
        CURRENT_LS_PATH=""
        ;;
    esac
  done < <("$LSREGISTER" -dump 2>/dev/null || true)
fi

if [[ "${#LS_REGISTERED_PATHS[@]}" -eq 0 ]]; then
  echo "No LaunchServices registrations found for $HOST_ID"
else
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    echo "  $path"
    if [[ "$path" != "$CANONICAL_APP" ]]; then
      CANDIDATES+=("$path")
    fi
  done < <(printf "%s\n" "${LS_REGISTERED_PATHS[@]}" | awk '!seen[$0]++')
fi


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
  "$SCRIPT_ROOT/.build" \
  "/Applications"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r path; do
    add_candidate "$path"
  done < <(find "$root" -type d -name "$APP_NAME.app" -prune -print 2>/dev/null || true)
done

UNIQUE=()
if [[ "${#CANDIDATES[@]}" -gt 0 ]]; then
  while IFS= read -r path; do
    [[ -n "$path" ]] && UNIQUE+=("$path")
  done < <(printf "%s\n" "${CANDIDATES[@]}" | awk '!seen[$0]++')
fi

echo "== PlugInKit registered extension paths =="
REGISTERED_EXT_PATHS=()
for id in "${EXTENSION_IDS[@]}"; do
  while IFS= read -r line; do
    case "$line" in
      *"Path = "*)
        ext_path="${line#*Path = }"
        [[ -n "$ext_path" ]] && REGISTERED_EXT_PATHS+=("$ext_path")
        ;;
    esac
  done < <(pluginkit -m -A -D -vvv -i "$id" 2>/dev/null || true)
done

if [[ "${#REGISTERED_EXT_PATHS[@]}" -gt 0 ]]; then
  while IFS= read -r ext; do
    [[ -n "$ext" ]] || continue
    if [[ "$ext" == "$CANONICAL_APP/"* ]]; then
      echo "Keep canonical: $ext"
      continue
    fi

    pluginkit -r "$ext" >/dev/null 2>&1 || true
    echo "Unregistered registered plug-in: $ext"

    parent_app="${ext%%/Contents/PlugIns/*}"
    if [[ -d "$parent_app" && "$parent_app" != "$CANONICAL_APP" ]]; then
      add_candidate "$parent_app"
    fi
  done < <(printf "%s\n" "${REGISTERED_EXT_PATHS[@]}" | awk '!seen[$0]++')

  UNIQUE=()
  if [[ "${#CANDIDATES[@]}" -gt 0 ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && UNIQUE+=("$path")
    done < <(printf "%s\n" "${CANDIDATES[@]}" | awk '!seen[$0]++')
  fi
else
  echo "No registered extension paths found."
fi

echo
echo "== Non-canonical app registrations found =="
if [[ "${#UNIQUE[@]}" -eq 0 ]]; then
  echo "None"
else
  printf "  %s\n" "${UNIQUE[@]}"
fi

echo
echo "== Unregister plug-ins from non-canonical copies =="
for path in "${UNIQUE[@]}"; do
  if [[ -d "$path/Contents/PlugIns" ]]; then
    while IFS= read -r ext; do
      [[ -d "$ext" ]] || continue
      pluginkit -r "$ext" >/dev/null 2>&1 || true
      ext_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ext/Contents/Info.plist" 2>/dev/null || true)"
      echo "Unregistered plug-in: ${ext_id:-unknown} @ $ext"
    done < <(find "$path/Contents/PlugIns" -type d -name '*.appex' -prune -print 2>/dev/null || true)
  fi
done

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
echo "== Remove disposable stale development copies =="
QUARANTINE_DIR="$HOME/Library/Caches/$HOST_ID/StaleAppCopies"
mkdir -p "$QUARANTINE_DIR"

for path in "${UNIQUE[@]}"; do
  case "$path" in
    *"/Library/Developer/Xcode/DerivedData/"*|*"/.build/"*|*"/Build/Products/"*)
      rm -rf "$path"
      echo "Removed development build copy: $path"
      ;;
    "/Applications/$APP_NAME.app.backup-"*)
      stamp="$(date +%Y%m%d-%H%M%S)-$RANDOM"
      destination="$QUARANTINE_DIR/$APP_NAME-$stamp.bundle-backup"
      mv "$path" "$destination"
      echo "Moved legacy Applications backup out of app search paths: $destination"
      ;;
    *)
      echo "Preserved non-canonical copy after unregister: $path"
      ;;
  esac
done

echo
echo "== Reset TCC only for this app identity =="
tccutil reset All "$HOST_ID" 2>/dev/null || true
for id in "${EXTENSION_IDS[@]}"; do
  tccutil reset All "$id" 2>/dev/null || true
done
echo "Scoped TCC reset complete. Other apps were not reset."

echo
echo "== Re-register canonical app/extension =="
if [[ -d "$CANONICAL_APP" ]]; then
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$CANONICAL_APP" >/dev/null 2>&1 || true
  fi
  if [[ -d "$CANONICAL_APP/Contents/PlugIns" ]]; then
    while IFS= read -r ext; do
      [[ -d "$ext" ]] || continue
      pluginkit -r "$ext" >/dev/null 2>&1 || true
      pluginkit -a "$ext" >/dev/null 2>&1 || true
      id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ext/Contents/Info.plist" 2>/dev/null || true)"
      [[ -n "$id" ]] && pluginkit -e use -i "$id" >/dev/null 2>&1 || true
    done < <(find "$CANONICAL_APP/Contents/PlugIns" -maxdepth 1 -type d -name '*.appex' -print 2>/dev/null || true)
  fi
else
  echo "Canonical app not found: $CANONICAL_APP" >&2
  exit 66
fi

echo
echo "== Refresh plug-in and Settings caches =="
killall pkd >/dev/null 2>&1 || true
killall Finder >/dev/null 2>&1 || true
killall "System Settings" >/dev/null 2>&1 || true
sleep 2

echo
echo "== Remaining LaunchServices registrations =="
REMAINING_LS=0
if [[ -x "$LSREGISTER" && -n "$HOST_ID" ]]; then
  CURRENT_LS_PATH=""
  while IFS= read -r line; do
    case "$line" in
      path:*)
        CURRENT_LS_PATH="${line#path:}"
        CURRENT_LS_PATH="${CURRENT_LS_PATH#"${CURRENT_LS_PATH%%[![:space:]]*}"}"
        CURRENT_LS_PATH="$(printf '%s\n' "$CURRENT_LS_PATH" | sed -E 's/[[:space:]]+\(0x[0-9A-Fa-f]+\)$//')"
        ;;
      identifier:*)
        CURRENT_LS_ID="${line#identifier:}"
        CURRENT_LS_ID="${CURRENT_LS_ID#"${CURRENT_LS_ID%%[![:space:]]*}"}"
        if [[ "$CURRENT_LS_ID" == "$HOST_ID" && -n "$CURRENT_LS_PATH" ]]; then
          echo "$CURRENT_LS_PATH"
          REMAINING_LS=$((REMAINING_LS + 1))
        fi
        ;;
      -------------------------------------------------------------------------------*)
        CURRENT_LS_PATH=""
        ;;
    esac
  done < <("$LSREGISTER" -dump 2>/dev/null || true)
fi
echo "LaunchServices registrations remaining: $REMAINING_LS"

echo
echo "== Canonical extension registrations =="
if [[ "${#EXTENSION_IDS[@]}" -eq 0 ]]; then
  echo "No canonical extension IDs detected."
else
  for id in "${EXTENSION_IDS[@]}"; do
    echo "-- $id"
    pluginkit -m -A -D -vvv -i "$id" 2>/dev/null || true
  done
fi

echo
if [[ -n "$HOST_ID" && "$REMAINING_LS" -gt 1 ]]; then
  echo "REGISTRATION_CLEANUP_INCOMPLETE remaining_launchservices=$REMAINING_LS" >&2
  exit 1
fi
echo "REGISTRATION_CLEANUP_PASS"
echo "macOS may ask for this app's permissions once again after the scoped TCC reset."
