# Branchlight Architecture

Branchlight is a Finder-native Git client for macOS. The architecture is intentionally split so Finder remains responsive while deeper Git work happens outside the Finder extension.

This document records the runtime invariants that repository intelligence, recovery, hosted-provider, AI, and distribution work must preserve.

## Product boundary

Branchlight is not a replacement Finder, code editor, terminal emulator, or Git implementation.

- Finder is the primary filesystem surface.
- Branchlight adds Git awareness and Git actions to that filesystem workflow.
- Deep workflows live in the native Branchlight Host UI.
- Git semantics continue to come from the system Git implementation.

## Current component model

```text
Finder
  |
  v
BranchlightFinderExtension
  |  in-memory cache reads + one-shot Finder intents
  v
App Group atomic JSON boundary
  ^
  |
BranchlightHost
  |
  +--> Host GitService adapter
  |     +--> read-only operations
  |     |     +--> BranchlightCore.InProcessGitService
  |     |           +--> SystemGitEngine
  |     |                 +--> /usr/bin/git
  |     |
  |     +--> every Git mutation
  |           +--> BundledGitXPCClient
  |                 +--> BranchlightGitService.xpc
  |                       +--> one GitOperationCoordinator
  |                       +--> one GitRepositoryRegistry
  |                       +--> InProcessGitService
  |                       +--> CoordinatedGitHistoryMutationService
  |                             +--> /usr/bin/git
  |
  +--> XPCRepositoryResolver
  |     +--> XPC identity/intelligence first
  |     +--> read-only in-process fallback only
  |
  +--> RepositoryWatcher (FSEvents)
```

The bundled XPC process is now the authoritative Git mutation owner. The Host keeps an in-process implementation only for read-only operations while that surface is migrated independently.

## Hard invariants

### 1. Finder callbacks are cache-only

The Finder extension must never perform a full Git status, spawn Git subprocesses, own long-running Git work, perform GitHub HTTP calls, or connect directly to the Git XPC service.

`requestBadgeIdentifier(for:)` must remain a cheap in-memory lookup against the latest shared status snapshot. Disk cache reload belongs to explicit cache-change/lifecycle events, not every badge callback.

### 2. Finder sends intent, not Git commands

Finder context actions describe user intent and selected paths. Execution belongs outside the extension.

Pending mutation intents are one-shot and freshness-bounded so a stale Stage/Unstage request cannot unexpectedly execute after a later application launch.

### 3. The shared boundary is versioned and atomic

Finder and the Host communicate through App Group state. Shared status and intent formats must remain explicitly versionable and compatible across rolling upgrades.

Writes remain atomic. Corrupt payloads are quarantined instead of being retried forever, with bounded forensic retention.

### 4. Git semantics come from real Git

Branchlight must not maintain a pretend index or parallel source-control model that can drift from Git.

Structured diff, line staging, history, blame, branch state, worktrees, stashes, merge/rebase state, recovery logic, and XPC execution ultimately reconcile with `/usr/bin/git` and repository filesystem state.

### 5. Mutations require exactly one authoritative owner

All state-changing Git operations converge on the bundled `BranchlightGitService.xpc` process and its shared repository coordinator.

The owner provides:

- repository-scoped serialization
- operation identity
- cancellation
- timeout policy
- preflight validation
- post-operation reconciliation
- journaling
- recovery metadata

The Host no longer executes Git mutations through its read-only in-process service. Stage, unstage, patch application, commit, fetch, pull, push, branch switching, merge/rebase controls, stash changes, worktree changes, cherry-pick, and revert all cross the XPC boundary.

An interrupted XPC mutation is never silently replayed through an in-process fallback. The remote process may have already changed Git state before the connection error became visible. Recovery is reconciliation-first, never blind retry.

### 6. Repository identity is not just a folder path

Repository identity distinguishes at least:

- working tree path
- Git directory
- common Git directory
- HEAD
- current branch or detached HEAD
- upstream
- linked worktree relationship

A linked worktree and the primary checkout may share Git storage while having independent working-tree state. Their mutation coordination key therefore follows common Git storage rather than only a visible folder path.

### 7. Repository state and presentation state are different

Git state must not be owned solely by a SwiftUI view model.

The Host UI projects repository state for presentation, but canonical runtime contracts are usable by Finder integration, native UI, background refresh, hosted-provider integration, AI context generation, and future automation without duplicating Git state machines.

### 8. XPC transport is bounded and versioned

The Host/XPC boundary uses a small Objective-C-compatible interface carrying bounded encoded payloads.

Current rules include:

- explicit protocol version
- per-request UUID
- bounded message size
- request/response identity validation
- fail-closed version mismatch
- Host-only connection ownership
- no credential transport
- exhaustive typed mutation enum rather than arbitrary command execution
- no mutation replay fallback

Adding an RPC requires typed request/response coverage and must not expose arbitrary command execution.

## Current responsibility pressure

`AppModel` still coordinates substantial presentation workflow:

- repository selection and restoration
- repository refresh
- Finder intent consumption
- diff loading and line selection
- staging and unstaging requests
- commit/fetch/pull/push requests
- history and blame presentation
- stash/worktree presentation
- conflict workspace presentation
- watcher ownership
- error and operation presentation

Those methods now request mutations from the XPC-owned runtime rather than owning mutation serialization themselves. Further extraction remains useful only where it materially reduces presentation/runtime coupling.

GitHub Live and AI Workbench already use independent Host models instead of returning those responsibilities to `AppModel`.

## Runtime target

```text
Finder Extension
      |
      | cache reads + intents
      v
Shared Boundary
      |
      v
Branchlight Host UI
      |
      v
BranchlightGitService.xpc
      |
      +--> RepositoryRegistry
      +--> GitOperationCoordinator
      +--> OperationJournal / checkpoints
      +--> safety admission
      +--> GitBackend
               |
               v
           /usr/bin/git
```

The mutation side of this target is implemented. Read-only Host operations remain independently migratable because they cannot create split mutation ownership.

## Runtime extraction / migration order

1. Repository identity and runtime-state models. **Implemented.**
2. Repository-scoped operation coordination. **Implemented.**
3. Structured operation journal/checkpoints and safety admission. **Implemented.**
4. Separate hosted-provider / AI presentation state from `AppModel`. **Implemented for those surfaces.**
5. Versioned/atomic Finder shared boundary. **Implemented and hardened.**
6. Physical bundled XPC target + versioned contract + Host client. **Implemented.**
7. Read-only XPC probe/repository-identity/intelligence vertical slice. **Implemented.**
8. Move the complete mutation/history surface to one XPC-owned coordinator. **Implemented.**
9. Remove Host in-process mutation ownership from the execution path. **Implemented.**
10. Signed development-Mac XPC/Finder runtime acceptance. **External acceptance gate.**

## Acceptance rules for runtime work

A runtime refactor is not accepted merely because it compiles. Each bounded change must preserve or add evidence for:

- Core unit tests
- real temporary-repository integration tests
- app-hosted real XPC process integration tests
- Host adapter → XPC → real Git mutation tests
- Finder cache-only behavior
- Finder selection intent freshness/one-shot behavior
- no Git subprocess/network/XPC dependency from Finder
- correct pre-first-commit handling
- detached-HEAD handling
- linked-worktree handling
- line/hunk staging
- stash/worktree flows
- merge/rebase/cherry-pick/revert and conflict flows
- runtime security boundary checks
- generated Xcode target coverage
- optimized Release bundle structure

XPC lifecycle changes additionally require a signed macOS build and real service launch/probe acceptance before external closure. Finder integration changes likewise require real signed Finder acceptance. GitHub CI cannot substitute for either runtime gate.

## Build-graph authority

`project.yml` is authoritative. CI regenerates `Branchlight.xcodeproj` with XcodeGen before compiling, and the canonical Release script regenerates it again before building. This prevents a stale generated project from omitting a newly introduced runtime target such as `BranchlightGitService.xpc`.

## Non-goals for the runtime phase

Do not use runtime migration as an excuse to add:

- AI agent autonomy that applies changes silently
- an embedded code editor
- a replacement file manager
- a custom Git implementation
- broad LFS/submodule/bisect surface expansion

Those additions would increase failure modes while ownership is being moved, which is an impressively human way to make a difficult migration worse.
