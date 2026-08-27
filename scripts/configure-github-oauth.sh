#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Config/Branchlight.oauth.local.xcconfig"
CLIENT_ID="${BRANCHLIGHT_GITHUB_CLIENT_ID:-${1:-}}"

if [[ -z "$CLIENT_ID" ]]; then
  echo "GitHub OAuth Client ID is required." >&2
  echo "Usage: bash scripts/configure-github-oauth.sh <CLIENT_ID>" >&2
  exit 64
fi

if [[ "$CLIENT_ID" =~ [[:space:]] ]]; then
  echo "GitHub OAuth Client ID must not contain whitespace." >&2
  exit 65
fi

cat > "$OUT" <<EOF
// Local-only GitHub OAuth configuration for Branchlight.
// GitHub OAuth Client IDs are public identifiers; do not put client secrets here.
BRANCHLIGHT_GITHUB_CLIENT_ID = $CLIENT_ID
EOF

echo "Configured GitHub OAuth client ID in $OUT"
echo "Next build will embed BranchlightGitHubClientID into Branchlight.app."
