# Branchlight

<p align="center">
  <a href="README.md"><strong>English</strong></a> | <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  <strong>Git belongs in Finder.</strong>
</p>

<p align="center">
  A Finder-native Git client for macOS that brings repository awareness, staging, interactive diffs, history, blame, stashes, branches, worktrees, and remote operations directly into the file workflow you already use.
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/uniplanck/Branchlight/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/uniplanck/Branchlight/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="Status Alpha" src="https://img.shields.io/badge/status-alpha-orange">
</p>

---

## Why Branchlight exists

Most Git clients ask you to leave the place where you are actually working.

You find a file in Finder, notice something changed, open a separate Git application, locate the repository again, locate the file again, inspect it again, and then perform the Git operation.

Branchlight flips that model around.

**Finder stays the center of the workflow. Git becomes ambient.**

Branchlight adds Git awareness to Finder itself, while keeping a compact native companion window for operations that deserve more space. You can see repository state where files live, act on the current Finder selection, and move into an interactive diff, history, blame, stash, branch, or worktree workflow without turning Finder into a heavyweight Git process host.

This is not a skin over `git status`. It is an architecture built specifically for a Finder-native Git experience.

## The short version

Branchlight currently provides:

- Finder status badges backed by a shared cache
- Finder context actions for **Show Changes**, **Stage Selected**, and **Unstage Selected**
- file, folder, multi-selection, and repository-root planning
- an interactive structured diff viewer
- whole-hunk staging and unstaging
- selected-line staging using reconstructed patches
- commit workflows
- fetch, push, and **fast-forward-only pull**
- branch listing and switching
- repository history
- selected-file history
- line-by-line blame
- stash create / apply / pop / drop
- worktree listing / creation / removal
- detached-HEAD and linked-worktree awareness
- pre-first-commit repository handling
- FSEvents-driven background refresh
- Finder/File Provider compatibility warnings
- a cache-only Finder extension that never runs full Git status work from badge callbacks

The current automated suite contains **33 passing unit and real temporary-repository integration tests** covering the core Git and cache behavior.

## Why it is different

| Workflow | Traditional desktop Git client | Branchlight |
| --- | --- | --- |
| Discover changed files | Open another app and locate the repo | See status in Finder |
| Stage a Finder selection | Re-find the same file in the Git client | Stage from Finder context menu |
| Review a patch | Switch completely into the Git app | Open Branchlight directly on the relevant changes |
| Stage part of a change | Depends on client-specific staging UI | Structured hunk and selected-line staging |
| File history / blame | Navigate through repository views | Inspect the file you already selected |
| Finder integration | Usually none | First-class product surface |
| Extension safety | Not applicable | Finder callbacks stay cache-only |
| Repository refresh | Usually app-centric polling/watchers | Host-side FSEvents + shared status snapshots |

Branchlight is intentionally **Finder-first, not Finder-only**. Deep Git work still belongs in a real native UI. The point is to remove needless context switching, not to force a miniature Git GUI into a context menu.

## Finder-native without making Finder fragile

Finder extensions run inside an environment where blocking, subprocess-heavy work is exactly what you do not want.

Branchlight therefore follows one hard architectural rule:

> **The Finder extension reads cached state. It does not run full Git operations from badge callbacks.**

```text
Finder
  |
  v
BranchlightFinderExtension
  |  cache-only reads + user intents
  v
App Group atomic JSON boundary
  ^
  |
Branchlight Host
  |
  +--> GitService
  |     +--> SystemGitEngine
  |           +--> /usr/bin/git
  |
  +--> FSEvents repository watcher
```

The host owns Git execution and refreshes repository state. Finder gets a cheap snapshot designed for fast status lookup and folder aggregation.

The shared boundary uses **atomic JSON files in the App Group container**, with migration from the earlier App Group preferences format. This avoids making Finder status delivery depend on synchronous `CFPreferences` traffic.

## Interactive staging

Branchlight parses Git diff output into structured files, hunks, and lines rather than treating a diff as a wall of text.

That enables two useful staging modes:

### Stage a whole hunk

Select the hunk and stage it directly.

### Stage only selected changed lines

Branchlight reconstructs a valid patch from the selected changes, preserves the necessary context, recalculates hunk ranges, and applies it to the index with Git.

This is deliberately built on real Git patch semantics rather than maintaining a parallel pretend-index inside the UI.

## Stashes, history, blame, and worktrees

Branchlight is already beyond the usual "Finder badges + a couple of menu commands" prototype.

### Stashes

Create a stash from the working tree, optionally include untracked files, then apply, pop, or drop stash entries from the native UI.

### File history

Select one file and switch the History view from repository history to that file's history.

### Blame

Inspect line-level commit attribution, including uncommitted lines, without leaving the selected-file workflow.

### Worktrees

List current worktrees, create a new worktree and branch at a chosen location, open it, or remove it safely from the UI.

## Safer defaults

Branchlight tries not to surprise you with destructive Git behavior.

Examples:

- pull uses `git pull --ff-only`
- branch switching warns when the working tree contains changes
- destructive stash removal requires confirmation
- worktree removal requires confirmation
- Finder multi-selection is planned against repository boundaries instead of blindly forwarding paths
- cross-repository Finder selections are rejected
- pre-first-commit repositories use an unstage path that still works before `HEAD` exists

## Repository awareness

The status engine understands more than the happy path:

- modified files
- staged files
- added files
- deleted files
- renamed files
- untracked files
- conflicts
- nested repositories
- detached `HEAD`
- linked worktrees
- repositories before the first commit

Folder badges aggregate the state of changed descendants, allowing Finder to communicate useful repository information without executing Git per item.

## File Provider caveat

macOS File Provider integrations such as iCloud Drive, Dropbox, OneDrive, Google Drive, and similar providers can take precedence over Finder Sync extensions for some Finder surfaces.

Branchlight detects likely File Provider-managed roots and warns instead of pretending it can override macOS extension priority.

That limitation belongs to the platform, not to Git.

## Current status

Branchlight is currently **v0.1.0 alpha**.

The core implementation and signed local runtime have been exercised with real Finder and Git workflows, including:

- Finder selection staging and unstaging
- interactive diff navigation
- stash save/pop round trips
- file history
- blame with committed and uncommitted lines
- worktree creation and removal
- window close/reopen lifecycle
- App Group cache persistence and legacy-cache migration

The project is source-first today. A generally downloadable Developer ID signed + notarized binary is not published yet.

## Quick start

### Requirements

- macOS 13 or later
- Xcode with Swift 6 support
- Git available at `/usr/bin/git`

The generated `Branchlight.xcodeproj` is committed, so **XcodeGen is not required just to build the project**. `project.yml` is included for contributors who prefer regenerating the project. For the full signing walkthrough, see [docs/BUILDING.md](docs/BUILDING.md).

### 1. Clone

```bash
git clone https://github.com/uniplanck/Branchlight.git
cd Branchlight
```

### 2. Verify the code without signing

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

This is the easiest way to build the core and run the test suite without configuring Apple signing.

### 3. Run the Finder integration

Finder Sync + App Group communication requires a locally signed build.

1. Open `Branchlight.xcodeproj` in Xcode.
2. Select your own Development Team for both `Branchlight` and `BranchlightFinderExtension`.
3. Change the app/extension bundle identifiers if necessary so they belong to your team.
4. Create an App Group owned by your team and enable it for both targets.
5. Replace `group.com.uniplanck.branchlight` in both entitlement files with your App Group identifier.
6. Build and run `Branchlight`.
7. Enable **Branchlight Finder Extension** in macOS System Settings if macOS does not enable it automatically. The exact System Settings location varies by macOS release.
8. Choose a Git repository in Branchlight.

Once the extension is active, Finder can consume the cached repository state and expose Branchlight actions for monitored repositories.

> If you only want to study the architecture or work on the Git engine/UI, you do not need to configure the Finder extension first.

## Build verification

Build only:

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run all tests:

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Project layout

```text
BranchlightCore/
  Git engine, status parsing, diff parsing/patch building,
  shared cache, repository models, selection planning, service boundary

BranchlightHost/
  SwiftUI/AppKit host application, repository watcher,
  interactive Git UI and Finder-intent handling

BranchlightFinderExtension/
  Thin Finder Sync extension: badges, menus, cached state and intents

BranchlightCoreTests/
  Unit tests + real temporary Git repository integration tests

project.yml
  XcodeGen project definition

docs/research/
  Product and architecture research
```

## Testing philosophy

Branchlight tests the Git behavior against **real temporary Git repositories**, not just mocked command output.

The suite covers scenarios including:

- status classification
- renames and deletion
- conflicts
- stage / unstage / diff / commit / history
- selected-line patch staging
- whole-hunk staging and unstaging
- clean repositories
- repositories before their first commit
- nested repositories
- detached HEAD
- linked worktrees
- local bare remotes with fetch / pull / push
- stash lifecycle
- file history and blame
- worktree lifecycle
- shared cache persistence and legacy migration
- Finder selection planning

This matters because Git's edge cases tend to live exactly where toy wrappers stop testing.

## Design principles

### 1. Finder is a first-class surface

Finder integration is not a launcher button bolted onto a desktop Git GUI.

### 2. Keep the extension thin

No full `git status` from `requestBadgeIdentifier(for:)`. No heavy Git subprocess lifecycle owned by Finder.

### 3. Use real Git semantics

Branchlight wraps the system Git engine behind a service boundary instead of inventing a second Git model that can drift from reality.

### 4. Make risky operations explicit

Operations that can destroy or materially rewrite state should be visible and confirmable.

### 5. Preserve an upgrade path

The UI talks to `GitService`, not directly to process-launch details. The current implementation uses an in-process service; the boundary leaves room for a durable XPC/single-Git-service architecture later.

## Roadmap

The current architecture is designed to grow into deeper workflows without making the Finder extension heavier.

Interesting next areas include:

- durable XPC / single Git service
- merge and rebase workflows
- conflict resolver
- richer commit detail views
- tags
- upstream / ahead / behind visualization
- submodules and Git LFS
- hosted GitHub/GitLab integrations
- Developer ID signed + notarized GitHub Releases

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing the Finder boundary or Git execution model; a few architecture invariants exist specifically to keep Finder responsive and predictable.

Bug reports, reproducible Git edge cases, Finder Sync behavior reports, and focused pull requests are especially useful.

## License

Branchlight is released under the [MIT License](LICENSE).

Use it, study it, fork it, improve it, ship ideas from it. Just keep the license notice with substantial copies of the software.

---

<p align="center">
  <strong>Branchlight makes Git feel less like a destination and more like part of the filesystem.</strong>
</p>
