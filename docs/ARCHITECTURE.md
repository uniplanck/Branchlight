# Architecture

Branchlight keeps Finder lightweight by separating presentation, shared cached state, and Git execution.

```text
Finder
  -> BranchlightFinderExtension
       -> cached status / intents only
  -> App Group atomic JSON boundary
  -> Branchlight Host
       -> GitService
       -> SystemGitEngine
       -> /usr/bin/git
```

## Finder extension

The Finder Sync extension reads cached repository snapshots and forwards user intents. It must not perform full Git scans from badge callbacks.

## Host application

The host owns repository selection, FSEvents monitoring, Git operations, interactive diff/history/stash/worktree UI, and refresh of shared snapshots.

## Git service boundary

SwiftUI code talks to `GitService`, not process-launch details. The current implementation uses an in-process service over `SystemGitEngine`; the boundary intentionally leaves room for a durable XPC/single-service implementation later.

## Shared status cache

Host and extension exchange status snapshots and one-shot Finder intents through atomic JSON files stored in the App Group container. Legacy App Group preferences data is migrated without making the runtime cache dependent on synchronous `CFPreferences` traffic.
