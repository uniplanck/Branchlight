#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
import sys

checks = {
    Path("BranchlightHost/BranchlightApp.swift"): [
        'accessibilityIdentifier("branchlight.main")',
        'accessibilityIdentifier("branchlight.github-live")',
        'accessibilityIdentifier("branchlight.ai-workbench")',
    ],
    Path("BranchlightHost/ContentView.swift"): [
        'accessibilityIdentifier("branchlight.addRepository")',
        'accessibilityIdentifier("branchlight.refresh")',
        'accessibilityLabel("Refresh repository")',
        'accessibilityIdentifier("branchlight.showDiff")',
        'accessibilityIdentifier("branchlight.stage")',
        'accessibilityIdentifier("branchlight.unstage")',
        'accessibilityIdentifier("branchlight.fetch")',
        'accessibilityIdentifier("branchlight.pull")',
        'accessibilityIdentifier("branchlight.push")',
        'accessibilityIdentifier("branchlight.commitMessage")',
        'accessibilityIdentifier("branchlight.commit")',
    ],
}

missing = []
for path, needles in checks.items():
    text = path.read_text()
    for needle in needles:
        if needle not in text:
            missing.append(f"{path}: {needle}")

if missing:
    print("Accessibility contract missing required identifiers/labels:")
    for item in missing:
        print(f"  {item}")
    sys.exit(1)

print("Accessibility source contract PASS")
PY
