# Contributing to Branchlight

Thanks for helping improve Branchlight.

Branchlight is intentionally opinionated about one thing: **Finder must stay responsive and lightweight even when Git work is not.** Most contribution rules follow from that constraint.

## Before you start

Please open an issue for large architectural changes before investing heavily in an implementation. Focused bug fixes, tests, parser improvements, Git edge cases, and small UX refinements are welcome as normal pull requests.

## Architecture invariants

### Finder extension stays thin

`BranchlightFinderExtension` should not own heavyweight Git execution.

In particular, do not add full Git status scans or long-running subprocess work to Finder badge callbacks such as `requestBadgeIdentifier(for:)`.

The intended flow is:

```text
Finder extension
  -> cached status + user intent
  -> App Group boundary
  -> Branchlight host / GitService
  -> Git engine
```

### UI should talk to GitService

Prefer extending `GitService` and `SystemGitEngine` instead of launching Git directly from SwiftUI views.

This keeps the UI testable and preserves the option to move Git execution behind XPC or another durable service later.

### Use real Git semantics

If an operation can be represented using normal Git primitives, prefer that over maintaining a parallel model that can drift from Git's index, refs, or worktree state.

### Be explicit with destructive operations

Operations that can discard or materially rewrite state should have clear UI intent and, where appropriate, confirmation.

## Development setup

Requirements:

- macOS 13+
- Xcode with Swift 6 support
- Git

The generated Xcode project is committed. You can open `Branchlight.xcodeproj` directly.

To build and test without signing:

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Finder integration development

A fully working Finder Sync build needs local Apple signing and an App Group shared by the host and extension.

Use identifiers owned by your own Apple Development team. Do not commit personal Team IDs, provisioning profiles, certificates, or other signing-specific material.

The repository defaults reference Branchlight's canonical bundle/App Group naming, but your local signing configuration may need different identifiers.

## Tests

Branchlight intentionally uses real temporary Git repositories in many integration tests.

When fixing a Git behavior bug, add a regression test when practical. Especially valuable cases include:

- unusual index/worktree combinations
- rename/delete/conflict behavior
- pre-first-commit repositories
- detached HEAD
- linked worktrees
- stash edge cases
- partial staging
- remote fetch/pull/push behavior

Avoid tests that mutate a developer's real repositories.

## Pull requests

A good pull request should:

1. explain the user-visible or architectural problem,
2. keep the Finder extension boundary intact,
3. include tests for Git behavior when practical,
4. avoid unrelated formatting or refactors,
5. keep local signing/provisioning data out of the diff.

## Code style

- Prefer clear Swift over clever abstractions.
- Keep Git process details inside the engine/service layer.
- Keep Finder callbacks bounded and cache-oriented.
- Make failure states visible rather than silently inventing state.
- Preserve macOS 13 compatibility unless a project-wide change explicitly raises the deployment target.

## License

By contributing, you agree that your contributions will be licensed under the repository's MIT License.
