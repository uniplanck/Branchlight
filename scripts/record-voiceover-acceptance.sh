#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.branchlight-local-acceptance"
FILE="$DIR/voiceover.accepted"

cat <<'EOF'
Before recording PASS, verify on the real Mac with VoiceOver enabled:
  - Add Repository is announced clearly
  - Refresh is announced clearly
  - Changes/Diff/History/Branches/Conflicts are navigable
  - Stage and Unstage are announced and usable
  - Fetch, Pull, Push are announced
  - Commit message field and Commit button are announced
  - Disabled/enabled states are understandable
EOF

printf "\nType ACCEPT to record the real-Mac VoiceOver acceptance: "
read answer
[[ "$answer" == "ACCEPT" ]] || { echo "Not recorded."; exit 64; }

mkdir -p "$DIR"
printf "accepted_at=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FILE"
printf "host=%s\n" "$(scutil --get ComputerName 2>/dev/null || hostname)" >> "$FILE"
echo "VOICEOVER_ACCEPTANCE_RECORDED"
