# Branchlight Architecture

Branchlight is a Finder-native Git client for macOS. The architecture is intentionally split so Finder remains responsive while deeper Git work happens outside the Finder extension.

This document records the baseline that future runtime, repository-intelligence, recovery, hosted-provider, and AI work must preserve.

## Product boundary

Branchlight is not a replacement Finder, code editor, terminal emulator, or Git implementation.

- Finder is the primary filesystem surface.
- Branchlight adds Git awareness and Git actions to that filesystem workflow.
- Deep workflows live in the native Branchlight host UI.
- Git semantics continue to come from the system Git implementation.

## Current component model

```text
Finder
  |
  v
BranchlightFinderExtension
  |  cache-only reads + Finder intents
  v
App Group atomic JSON boundary
  ^
  |
BranchlightHost
  |
  +--> GitService
  |     +--> InProcessGitService
  |           +--> SystemGitEngine
  |                 +--> /usr/bin/git
  |
  +--> RepositoryWatcher (FSEvents)
```

## Hard invariants

### 1. Finder callbacks are cache-only

The Finder extension must never perform a full Git status, spawn Git subprocesses, own long-running Git work, or synchronously wait on the host.

`requestBadgeIdentifier(for:)` must remain a cheap lookup against the shared status snapshot.

### 2. Finder sends intent, not Git commands

Finder context actions describe user intent and selected paths. Execution belongs outside the extension.

This keeps Git execution policy, validation, serialization, cancellation, journaling, and recovery in one place.

### 3. The shared boundary is versioned and atomic

Finder and the host communicate through App Group state. Shared status and intent formats must remain explicitly versionable and compatible across rolling upgrades.

Writes must remain atomic so Finder never consumes partially-written state.

### 4. Git semantics come from real Git

Branchlight must not maintain a pretend index or a parallel source-control model that can drift from Git.

Structured diff, line staging, history, blame, branch state, worktrees, stashes, merge/rebase state, and future recovery logic must ultimately reconcile with real Git state.

### 5. Mutations require a single owner

The current in-process service is an implementation detail, not the final ownership model.

All state-changing Git operations must converge on one coordinator that can provide:

- repository-scoped serialization
- operation identity
- cancellation
- timeout policy
- preflight validation
- post-operation refresh
- journaling
- recovery metadata

Two independent UI surfaces must not mutate the same repository concurrently without coordination.

### 6. Repository identity is not just a folder path

Future multi-repository and worktree support must distinguish at least:

- working tree path
- Git directory
- common Git directory
- HEAD
- current branch or detached HEAD
- upstream
- linked worktree relationship

A linked worktree and the primary checkout may share Git storage while having independent working-tree state.

### 7. Repository state and presentation state are different

Git state must not be owned solely by a SwiftUI view model.

The host UI may project repository state for presentation, but the canonical runtime model must be usable by Finder integration, the native UI, background refresh, hosted-provider integration, and future automation without duplicating Git state machines.

## Current pressure points

The existing architecture is healthy for the v0.1 alpha feature set, but these responsibilities currently converge in `AppModel`:

- repository selection and restoration
- repository refresh
- Finder intent consumption
- diff loading and line selection
- staging and unstaging
- commit/fetch/pull/push mutations
- history and blame loading
- stash lifecycle
- worktree lifecycle
- watcher ownership
- error and operation presentation

Adding merge, rebase, conflict resolution, multi-repository monitoring, operation recovery, GitHub state, and AI review directly to the same object would create a single oversized state machine.

## Runtime target

```text
Finder Extension
      |
      | cache reads + intents
      v
Shared Boundary
      |
      v
Branchlight Runtime
      |
      +--> RepositoryRegistry
      +--> RepositoryStateEngine
      +--> GitOperationCoordinator
      +--> OperationJournal
      +--> StatusCache
      +--> GitBackend
               |
               v
           /usr/bin/git
      ^
      |
Branchlight Host UI
```

The runtime may initially remain in-process while its contracts are extracted. Durable XPC ownership is the later transport/lifecycle step; the logical ownership boundary comes first.

## Runtime extraction order

1. Introduce repository identity and runtime-state models.
2. Introduce repository-scoped operation coordination.
3. Move mutation orchestration out of `AppModel`.
4. Separate repository data state from UI presentation state.
5. Make the Finder/host shared boundary explicitly versioned.
6. Add operation journal contracts.
7. Move the runtime behind an XPC boundary without changing host-facing semantics.

## Acceptance rules for runtime work

A runtime refactor is not accepted merely because it compiles. Each bounded change must preserve or add evidence for:

- existing Core unit tests
- real temporary-repository integration tests
- Finder cache-only behavior
- Finder selection intent behavior
- no direct Git execution from the Finder extension
- correct pre-first-commit handling
- detached-HEAD handling
- linked-worktree handling
- no regression in line/hunk staging
- no regression in stash/worktree flows

Changes that affect runtime lifecycle also require a signed macOS build and real Finder integration verification before final acceptance.

## Non-goals for the runtime phase

Do not add these while runtime ownership is still being extracted:

- full GitHub dashboard behavior
- AI agent autonomy
- embedded code editor
- replacement file manager
- custom Git implementation
- broad LFS/submodule/bisect feature expansion

Those features depend on a stable repository and operation model and must not be used to bypass it.
