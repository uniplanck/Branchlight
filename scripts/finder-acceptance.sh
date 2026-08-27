#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_NAME="${1:-branchlight-finder-acceptance.txt}"
PROBE="$ROOT/$PROBE_NAME"

cd "$ROOT"

if git check-ignore -q -- "$PROBE_NAME"; then
  echo "Refusing ignored Finder acceptance probe: $PROBE_NAME" >&2
  git check-ignore -v -- "$PROBE_NAME" >&2 || true
  exit 64
fi

if [[ -e "$PROBE" ]]; then
  echo "Probe already exists: $PROBE" >&2
else
  printf "Branchlight Finder acceptance probe\n" > "$PROBE"
fi

echo "Probe: $PROBE"
echo
echo "Git status:"
git status --short -- "$PROBE_NAME"
echo
echo "Expected Finder menu before staging:"
echo "  Status: Untracked"
echo "  Stage Selected"
echo
echo "After Stage Selected:"
echo "  Status: Staged"
echo "  Unstage Selected"
echo
echo "After Unstage Selected:"
echo "  Status: Untracked"
echo "  Stage Selected"
