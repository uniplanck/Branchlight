# Testing

Branchlight combines parser/unit tests with integration tests that create real temporary Git repositories.

The current suite covers status parsing, Finder selection planning, shared cache behavior and migration, diff parsing, hunk/line staging, commits/history, remotes, detached HEAD, linked worktrees, pre-first-commit behavior, stashes, blame/file history, and worktree lifecycle.

Run the full suite without signing:

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test
```

Tests must not mutate a developer's real repositories.
