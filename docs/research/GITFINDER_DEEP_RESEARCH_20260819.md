# Branchlight Research: Finder-native Git Client

Date: 2026-08-19
Status: Research baseline + P0 implementation snapshot (updated 2026-08-19)
Codename: Branchlight (temporary; branding is intentionally replaceable)

## Executive conclusion

The product opportunity is not “another full-screen Git GUI”. GitFinder’s durable advantage is ambient Git awareness inside Finder: status badges where files already live, then contextual actions without first opening a separate client. The strongest design for a 2026 product is therefore a thin Finder surface backed by one shared Git/status service and a native host app for richer workflows.

Branchlight should NOT put every Git command into Finder menus. Finder should remain the navigation surface. Badge/status, a small contextual action set, and fast entry points belong in Finder. Diff, commit, history, conflict resolution, branch management and other stateful/destructive workflows should open compact native Branchlight UI.

### Confirmed platform constraints

- Finder Sync supports monitored folders, badge/label updates, contextual menus, toolbar items and sidebar icons.
- Finder Sync instances can be long-lived, and extra extension instances can be created for Open/Save panels.
- Apple explicitly recommends keeping the extension focused on badges/menu/toolbar and placing state updates/remote work in one separate service.
- Badges should be provided on demand for visible items instead of eagerly updating huge directory trees.
- GitFinder documents a practical File Provider collision: folders managed by File Provider based services such as iCloud Drive, Dropbox, OneDrive, Google Drive and Synology Drive can prevent GitFinder’s Finder Sync badges/menu from appearing because the File Provider integration takes precedence.
- User-selected folder access and security-scoped bookmarks are the normal sandbox-safe way to persist access to repository parent folders.

### Product decision

Use this architecture direction:

```text
Finder
  -> BranchlightFinderExtension (very thin)
       -> cached status only / contextual intents only
  -> shared state boundary
       -> Branchlight Git Service (single process in production)
            -> GitEngine protocol
                 -> CLI Git first
                 -> optional libgit2 read accelerator later
            -> repository index
            -> incremental status cache
            -> file-system watcher/debounce

Branchlight Host App
  -> onboarding / monitored roots
  -> diff / commit / history / branch UI
  -> settings / diagnostics
```

P0 starts with the same boundaries but uses a simpler host-driven cache refresh before the durable background/XPC service is added. This validates Finder behavior and status correctness without prematurely building an agent/service subsystem.

---

# 1. GitFinder complete feature inventory

Legend:
- **Confirmed**: present in GitFinder’s public website, release notes, support or reproducible public UI description.
- **Inference**: design/behavior inferred from several public sources, not claimed as exact internal implementation.
- **Unconfirmed**: not enough evidence found; do not market as a GitFinder feature.

## 1.1 Finder integration

| Capability | Status | Publicly confirmed behavior |
|---|---|---|
| Finder status badges | Confirmed | Descriptive icon badges show Git file status directly in Finder. |
| Finder contextual menu | Confirmed | Git operations exposed from customizable Finder contextual menus. |
| Finder toolbar menu | Confirmed | Git operations can be exposed through a customizable Finder toolbar menu. |
| Monitored repository roots | Confirmed | User adds repository parent folders in Preferences so the Finder Sync extension can monitor/access them. |
| Selected-file diff | Confirmed | Selected Finder files can open a separate quick diff window. |
| Selected-file history | Confirmed | Complete file history can be opened. Later releases made history rename-aware. |
| Selected-file blame | Confirmed | Blame opens in a separate window. |
| Conflict action from Finder/client | Confirmed | Can choose one conflicted version or use a configured merge tool. |
| Quick Look integration | Unconfirmed | No reliable public evidence found that GitFinder provides a dedicated Quick Look extension. |
| Finder Preview extension | Unconfirmed | Do not assume. |
| Other file managers | Confirmed absent | GitFinder support states Finder integration is Finder-only. |

## 1.2 Repository / working copy operations

Confirmed from the product site and release notes:

- Create repository
- Clone repository
- Stage / unstage
- File/hunk/line-level stage and unstage (added through releases)
- Discard changes at supported granularities
- Diff staged vs unstaged changes
- Commit
- Amend
- Checkout branch/revision
- Cherry-pick
- Revert
- Merge
- Rebase
- Stash; later partial file stashing
- Local and remote branch management
- Local and remote tag management
- Remote repository create/delete for supported hosting integration
- Repository history / commit browser
- File history
- Blame
- Submodules
- Git LFS
- Global ignore support
- Git hooks for documented hook points
- Patch application
- External diff/merge tool integration
- Keyboard shortcuts, including customizable shortcuts and contextual shortcut cheat sheet

## 1.3 Hosting integration

Confirmed through GitFinder 1.5+ and 1.7 release notes:

- GitHub account/host integration
- GitLab account/host integration
- Bitbucket account/host integration
- Pull-request workflows: create/edit/comment/merge/close in 1.7-era releases
- Publish a local repository to a configured host account

## 1.4 Repository browser

Confirmed product surface:

- local branches
- remote branches
- tags
- submodules
- commit/history browsing
- diff views
- settings and repository operations

## 1.5 Implementation details that are publicly stated

- GitFinder uses an embedded Finder Sync extension named GitFinderSync for Finder integration.
- GitFinder’s author publicly states the application does not use the Git CLI and relies on a separate Git library; an older design article identifies libgit2 as the chosen foundation.
- GitFinder documents sandbox/Finder Sync access setup through repository parent folders.

Do not infer any non-public GitFinder source code, IPC protocol, cache representation, algorithms or private assets from this.

---

# 2. Why GitFinder is useful

## Confirmed/strongly supported

1. **Ambient awareness**. The most distinctive utility is seeing dirty repositories/files while already browsing Finder, without opening each repository in a client.
2. **Low workflow switching cost**. Common commands begin where the file is selected.
3. **TortoiseGit-like mental model on macOS**. Multiple public comments describe this as the reason the product is attractive.
4. **More than a shell extension**. It also supplies a repository browser and advanced operations, so users do not necessarily need a second Git client for every task.
5. **One-time-purchase appeal** was praised in an older MacUpdate review relative to subscription clients.

## Product interpretation

The actual moat is context, not command count. A clone that merely adds 40 Git submenu items would reproduce complexity while missing the reason users like the product.

---

# 3. GitFinder weaknesses and user voice

Public review volume for GitFinder is small. Searches across Reddit, Hacker News, Stack Overflow, Japanese reviews and general web indexing did not produce enough independent current user reports to support statistical claims. Therefore frequency labels below are deliberately conservative.

| Signal | Evidence strength | Classification | Interpretation |
|---|---|---|---|
| Finder status-at-a-glance is valuable | Medium | Praise | Repeated in product positioning and independent forum/review comments. |
| TortoiseGit-like workflow is attractive | Medium | Praise | Mentioned by independent users/comparison sites. |
| Documentation/preferences can be unintuitive | Low | UX complaint | Detailed MacUpdate review explicitly called documentation insufficient and some settings difficult to infer. |
| Very many repositories can hurt responsiveness | Low/Medium | Performance | A XenForo user reported some struggle with 137 repositories; GitFinder release history also repeatedly contains status/badge/performance fixes. |
| Blame/window lifecycle and navigation felt transient/clunky | Low | UX complaint | XenForo user wanted a more persistent “proper client” experience; blame window could disappear and reload. |
| Users may still pair it with GitKraken/Tower/IDE tooling | Low/Medium | Workflow gap | Forum comments show users retaining other clients for Git Flow/full-client workflows even while valuing Finder integration. |
| File Provider folders can lose Finder Sync UI | High | Platform limitation | GitFinder’s own support page documents the limitation. This is not merely a GitFinder bug. |
| Setup depends on enabling the Finder extension and monitored roots | High | Onboarding friction | Official support documents manual extension/parent-folder setup. macOS versions have moved the extension-management UI. |
| Release cadence is slower than some major competitors | Medium | Product risk / inference | GitFinder release notes currently top out at 1.7.11 dated 2025-02-26, while Fork/Tower published significant 2026 releases. This does not prove abandonment. |

### What users appear to want but GitFinder alone does not fully solve

- parent-level view across many repositories, fast enough to remain always-on
- persistent full-client windows when deeper work begins
- modern branch/worktree workflows
- richer conflict assistance
- high-speed keyboard launch/action search
- better onboarding and clearer explanations for Git beginners
- modern optional AI assistance, without turning basic Git into an AI dependency

### No evidence / do not overclaim

- No evidence was found for a broad wave of users quitting GitFinder for one specific reason.
- No large trustworthy dataset was found for price complaints.
- Indexed Reddit/HN/Stack Overflow/Japanese commentary was too sparse to assign meaningful percentages.
- Lack of indexed discussion is not evidence of lack of users.

---

# 4. Competitive research

## Fork

High-value patterns to learn from:

- fast native-feeling repository workflow
- line-by-line stage/unstage
- advanced diff and image diff
- built-in conflict resolver
- interactive rebase
- reflog
- LFS/GPG/Git Flow
- file/directory history and blame
- 2026-era worktree support
- quick/fuzzy launch patterns
- recent optional AI agent integrations for commit messages/code review

Lesson: Branchlight must not treat worktrees, precise staging and fast command access as exotic “power user later” concepts forever.

## Tower

High-value patterns:

- strong undo/safety story
- Quick Actions style command access
- conflict workflows
- automatic/individual-file stash
- branch review/mergeability/ahead-behind context
- worktree improvements
- hosted PR context
- AI commit assistance in current generations

Lesson: destructive Git operations need understandable previews and recovery semantics, not merely confirmation dialogs.

## Sublime Merge

High-value patterns:

- performance-first UI
- line-level staging
- side-by-side syntax-aware diff
- command palette
- exact Git command visibility
- built-in merge handling
- blame/history/submodules

Lesson: advanced users trust a GUI more when the operation is fast and transparent. “Show command / copy command” is a useful expert affordance even if Branchlight itself executes through an engine abstraction.

## GitHub Desktop

High-value patterns:

- approachable branch/pull/push mental model
- visual commit changes
- stash-on-branch-switch flow
- amend/revert/cherry-pick/reorder/squash
- merge/rebase with clear prompts
- deep GitHub pull-request handoff/integration

Lesson: beginner UX is mostly vocabulary, sequencing and safe defaults, not removal of Git concepts.

## Sourcetree

High-value patterns:

- file/hunk/line staging
- branch graph
- Git Flow
- LFS/submodule support
- interactive rebase
- embedded/system Git selection

Lesson: engine configurability is useful, but the UI can become dense. Branchlight should avoid recreating a dashboard-first information wall inside Finder.

## SmartGit

High-value patterns:

- clean commit shaping (split/squash/reorder)
- built-in 3-way conflict solver
- journaling/history orientation
- GitHub/GitLab/Bitbucket/Gerrit integrations
- stash-on-demand and LFS

Lesson: P1/P2 can add “explain the repository state” and conflict-resolution workflows without expanding the Finder surface itself.

---

# 5. Feature matrix

Legend: あり = confirmed current/public capability; なし = not a normal product capability; 部分対応 = available with limits or external handoff; 今回追加 = Branchlight target; 将来追加 = Branchlight later phase.

| Feature | GitFinder | Fork | Tower | Sublime Merge | GitHub Desktop | Branchlight |
|---|---|---|---|---|---|---|
| Finder file badges | あり | なし | なし | なし | なし | 今回追加 P0 |
| Finder contextual Git actions | あり | なし | なし | なし | なし | 今回追加 P0 |
| Parent-folder multi-repo awareness | あり | 部分対応 | 部分対応 | 部分対応 | 部分対応 | 今回追加 P0/P1 |
| Quick diff | あり | あり | あり | あり | あり | 今回追加 P0 |
| Stage/unstage | あり | あり | あり | あり | あり | 今回追加 P0 |
| Hunk/line staging | あり | あり | あり | あり | 部分対応 | 将来追加 P1 |
| Commit/amend | あり | あり | あり | あり | あり | 今回追加 P0 / amend P1 |
| Fetch/pull/push | あり | あり | あり | あり | あり | 今回追加 P0 |
| Branch view/switch/create | あり | あり | あり | あり | あり | 今回追加 P0/P1 |
| Merge/rebase | あり | あり | あり | あり | あり | 将来追加 P1 |
| Interactive rebase | 部分対応/あり | あり | あり | あり | 部分対応 | 将来追加 P2 |
| Stash | あり | あり | あり | あり | あり | 将来追加 P1 |
| History | あり | あり | あり | あり | あり | 今回追加 P0 |
| File history | あり | あり | あり | あり | 部分対応 | 将来追加 P1 |
| Blame | あり | あり | あり | あり | 部分対応 | 将来追加 P1 |
| Built-in conflict UI | 部分対応/external merge | あり | あり | あり | 部分対応 | 将来追加 P1 |
| Tags | あり | あり | あり | あり | あり | 将来追加 P1 |
| Submodules | あり | あり | あり | あり | 部分対応 | 将来追加 P2 |
| Git LFS | あり | あり | あり | 部分対応 | 部分対応 | 将来追加 P2 |
| Worktrees | 未確認/弱い | あり (2026) | あり | 部分対応 | 部分対応 | 将来追加 P1 |
| Reflog UI | 未確認 | あり | あり/部分対応 | 部分対応 | なし | 将来追加 P2 |
| GitHub/GitLab/Bitbucket PR UI | あり | 部分対応 | あり | なし | GitHubのみ強い | 将来追加 P2 |
| Command palette / fuzzy action launcher | 未確認 | あり | あり | あり | 部分対応 | 将来追加 P1 |
| AI commit message | 未確認 | あり (current releases) | あり | 未確認 | 未確認 | 将来追加 P2 optional |
| AI diff explanation | 未確認 | 部分対応/agent | 部分対応 | 未確認 | 未確認 | 将来追加 P2 optional |
| File Provider-safe Finder badges | なし（OS制約） | N/A | N/A | N/A | N/A | なし（OS制約を明示） |

“GitFinder upper-compatible” is therefore defined as:

> Preserve GitFinder’s ambient Finder advantage, match its daily-core Git operations, then exceed it in performance architecture, persistent native workflows, worktree/keyboard UX, onboarding, safety and optional 2026-era AI assistance.

---

# 6. Opportunity analysis

## P0-winning opportunities

1. **Badge latency**: badge requests must be cache reads, never synchronous `git status` executions.
2. **Folder aggregation**: a repository folder should visibly indicate dirty/conflict state even when the changed file is deeper. This directly supports the multi-repo “which repo is dirty?” use case.
3. **Minimal contextual menu**: show only operations valid for the current selection/state. Put the rest behind “Open in Branchlight…” or a palette.
4. **Persistent compact windows**: quick diff/history/commit should survive app switching and be reachable again.
5. **Explainable status**: show plain-language state (“3 modified, 1 staged, 2 untracked; branch is 2 ahead”) beside raw Git labels.
6. **Safety**: destructive actions show affected files and a precise Git-level effect before execution.
7. **Monorepo/large-repo design**: one index/cache per worktree; invalidation/debounce instead of full rescans per Finder callback.

## P1/P2 opportunities

- worktree-first branch workflow
- branch health: ahead/behind, upstream, stale/merged cues
- built-in conflict resolver
- file/hunk history
- semantic history search
- Quick Action palette with keyboard-first operation
- “show/copy exact Git command” expert affordance
- GitHub/GitLab/Bitbucket PR metadata in the host app
- image diff and binary metadata diff

## AI opportunities

Use AI only where language/semantic reasoning adds value:

Good candidates:
- explain a diff
- draft a commit message from staged diff
- summarize repository state
- explain likely conflict intent, while leaving edits explicit
- semantic commit-history search
- answer “what changed here?” from diff/history

Bad candidates:
- computing Git status
- deciding whether a file is tracked
- stage/unstage itself
- branch/ref lookup
- file watching/cache invalidation

AI must be optional and provider-abstracted. No repository content should leave the Mac by default. A future local-model path is desirable but not necessary for P0.

---

# 7. P0 / P1 / P2 / P3

## P0: daily usable Finder Git

Target: prove that Branchlight is useful every day before adding a complete Git GUI.

- monitored-root onboarding
- repository/worktree recognition
- Finder status badges: conflict, modified, added, deleted, renamed, untracked, staged
- aggregate folder/repository badge
- branch name + clean/dirty summary
- Finder contextual menu with state-aware minimal commands
- refresh status
- quick diff
- stage / unstage selected files
- commit staged changes
- fetch / pull / push
- branch list + safe switch
- recent repository history
- shared status cache
- basic large-repo debounce/invalidation contract
- errors surfaced in host UI, no secrets in logs

### P0 implementation snapshot — 2026-08-19

Implemented and compile/test validated:

- native SwiftUI host app + Finder Sync Extension + shared `BranchlightCore`
- CLI-first `GitEngine` using `/usr/bin/git`
- real Git status parsing across clean/modified/untracked/staged/deleted/renamed/conflict states
- nested repository, linked worktree, detached HEAD and repository-without-first-commit handling
- shared App Group cache, aggregate folder status and Darwin notification reload signal
- host-side FSEvents watcher with debounce/invalidation refresh; watcher-triggered refresh recomputes status/cache only, while explicit/mutation refreshes also reload branch/history metadata
- host warning for repositories under likely File Provider-managed roots (`~/Library/CloudStorage` and iCloud `Mobile Documents`)
- quick diff, stage/unstage, commit, fetch, `pull --ff-only`, push, branch list/switch and recent history
- Finder status display + `Show Changes` + state-aware Stage/Unstage intents forwarded to the host app; the extension still never executes Git
- Finder file/folder/root selection planning extracted into shared Core logic and tested, including rejection of cross-repository multi-selection
- integration tests using temporary repositories and a local bare remote; the latest full suite after selection-planner coverage is 23/23 PASS

Not yet runtime-proven:

- signed App Group container sharing between the host and Finder extension
- actual Finder badge/menu behavior after enabling the signed extension in System Settings
- File Provider collision behavior on real iCloud/Dropbox/OneDrive-managed roots

The remaining P0 risk is therefore primarily signed Finder integration, not core Git command correctness.

## P1: modern power workflow

- hunk/line staging
- stash / partial stash
- file history + rename following
- blame
- worktree create/open/remove
- branch create/delete/merge/rebase
- tags
- conflict resolver
- quick command/action palette
- filesystem watcher + durable single Git service/XPC architecture
- ahead/behind/upstream indicators

## P2: hosted/advanced workflows

- GitHub/GitLab/Bitbucket PR integration
- submodule UX
- Git LFS + lock/unlock where applicable
- reflog/recovery UI
- interactive rebase
- patch workflows
- image diff
- semantic history search
- optional AI commit/diff/conflict explanations

## P3: specialist/enterprise

- GPG/signing workflows
- custom credential/SSH enterprise edge cases
- stacked-branch workflows
- richer hosting enterprise integrations
- advanced automation/workflow templates
- plugin/extension surface only if real demand appears

---

# 8. Technical selection

## Finder API

**Decision: Finder Sync Extension for P0.**

Reason: it is the public API that directly provides monitored folders, badge identifiers, contextual menus and a toolbar surface. Apple’s own documentation warns that Finder Sync is not a generic Finder customization framework, so Branchlight should keep its Finder footprint narrow and aligned with these supported capabilities.

## Host/service split

**Decision: Host App + Finder Extension + Shared Git Service/Cache.**

The extension must never perform a repository-wide status scan in `requestBadgeIdentifier(for:)`. Production architecture should have one status service and multiple thin extension clients. Current P0 uses the host app as the Git worker, with explicit refresh plus a debounced FSEvents watcher writing into the shared cache; the Finder extension remains cache-only.

## Git engine comparison

| Engine | Compatibility | Sandbox/distribution | Performance/control | Maintenance | License | Decision |
|---|---|---|---|---|---|---|
| `/usr/bin/git` / selected Git CLI | Highest real-Git behavior, hooks/config/credentials | External execution conflicts with strict sandbox assumptions; viable for direct-distribution helper/service architecture | Excellent enough; process startup can be amortized/batched | Low | Git GPLv2, invoked separately | **P0 primary** |
| Homebrew Git only | High | Not guaranteed installed/path stable | Good | User dependency | GPLv2 | No as hard dependency; allow custom path later |
| libgit2 | Broad but not identical to CLI ecosystem | Embeddable; friendlier to sandboxed architecture | Fine-grained and fast for reads | Medium/high integration burden | GPLv2 with linking exception | Optional future read/status engine or App Store path |
| SwiftGit2 | Swift wrapper around libgit2 | Embeddable | Convenient API conceptually | Repository currently presents Carthage/manual integration and no modern SPM-first path in README; risk for Swift 6/macOS 26 | MIT wrapper + libgit2 terms | Do not adopt for P0 |
| Own Git implementation | Unknown/risky | Full control | Enormous scope | Very high | Ours | Drop |

### Engine decision rationale

Branchlight is initially targeted as a direct macOS native app, not an App Store-first product. The fastest path to Git correctness is therefore to keep a `GitEngine` protocol and use the system/user-selected Git executable in a non-Finder service. This inherits real Git semantics for worktrees, config, hooks, credentials and future features.

The Finder extension remains sandboxed and never launches Git. If a future App Store distribution requirement makes that architecture unacceptable, the engine boundary lets us replace read/status paths with libgit2 and reevaluate mutation/credential flows without rewriting product UI.

On the development Mac audited 2026-08-19:
- macOS 26.5.2
- Xcode 26.6
- Swift 6.3.3
- Apple Git 2.50.1
- XcodeGen installed at `/usr/local/bin/xcodegen`

## License plan

- Branchlight source: MIT License target.
- P0: no third-party linked library required.
- Git CLI is invoked as a separately installed system tool; it is not copied into the repository or redistributed in P0.
- libgit2, if later linked, uses GPLv2 with a linking exception and requires preserving its notices/conditions.
- SwiftGit2 itself declares MIT, but is not selected for P0.

This is engineering license analysis, not legal advice.

---

# 9. Architecture

## Components

### BranchlightFinderExtension
Responsibilities:
- register monitored roots
- register badge images/labels
- answer badge requests from local cached state only
- expose contextual and toolbar actions
- forward intents/open Branchlight UI

Must not:
- execute `git status` per badge callback
- perform network operations
- own credentials
- recursively scan repositories
- contain hosting API clients

### BranchlightCore
Pure/shared logic:
- Git status model
- porcelain parser
- repository identity/worktree model
- status prioritization and folder aggregation
- GitEngine protocol
- shared cache serialization

### Branchlight Host App
P0:
- onboarding and monitored roots
- explicit refresh plus debounced FSEvents refresh while the host is running
- repository/branch/status summary
- diff, stage/unstage, commit, fetch/pull/push, branch switch and recent history
- consume Finder intents and execute Git outside the Finder extension

P1 production service boundary:
- move watcher/Git execution from host ownership into one durable XPC/background service
- debounce/coalescing and incremental repository discovery/index
- bounded Git process execution
- cache updates independent of host-app lifetime
- remote operations and richer diagnostics

## Cache rules

- Cache key includes worktree/repository root and absolute/normalized file path.
- Finder callbacks read memory/shared cache only.
- Folder status is derived by prefix aggregation, with priority conflict > working-tree changes > staged > clean.
- Cache carries revision and timestamp so extension can reload only when state changes.
- Refresh only repositories affected by file events or explicit user action.
- Remote fetch must never be triggered merely because Finder displays a directory.

## File Provider limitation

Treat cloud/File Provider collision as an explicit compatibility boundary. Do not hack around Apple’s extension precedence. Detect/document likely unsupported roots and offer host-app status even when Finder badges cannot be shown.

---

# 10. Product design

## Finder surface

Badge vocabulary should stay visually small:
- conflict
- modified
- staged
- untracked
- added
- deleted
- renamed

Do not encode branch/ahead/behind into seven more tiny badge glyphs. Show those in toolbar/popover/host summary.

Context menu top level should be state-aware and short, for example:

```text
Branchlight
  Show Changes
  Stage / Unstage
  Commit…
  Pull / Push (only when meaningful)
  Open Repository
  More Git Actions…
```

Avoid twenty sibling Git commands. Finder is a file manager, despite developers’ heroic attempts to make every surface a cockpit.

## Beginner / expert duality

Beginner surface:
- plain language status
- safe verbs
- effects preview
- sensible defaults

Expert surface:
- exact refs/status
- keyboard-first palette
- copy/show Git command
- full diff metadata
- fast batch selection

---

# 11. Risks

| Risk | Severity | Mitigation |
|---|---:|---|
| Finder becomes slow due status scans | Critical | Cache-only extension callbacks; single service; debounce; visible-item demand. |
| File Provider suppresses Finder Sync integration | High | Explicit unsupported/limited mode; host UI fallback. |
| Extension lifecycle/process multiplicity causes duplicate work | High | Extension owns no Git worker; one production service. |
| Large monorepo status cost | High | Incremental invalidation, pathspec/batched queries, watcher, benchmark fixture. |
| CLI availability/path differences | Medium | engine discovery and user-selectable Git path; clear diagnostics. |
| Sandbox/App Store architecture conflicts with external Git | High if App Store chosen | direct distribution first; engine abstraction; libgit2 alternative. |
| Credential leakage | Critical | never log env/remote credentials; defer auth to Git credential mechanisms/keychain/host integration. |
| Destructive Git UI | High | preview + explicit confirmation + undo/recovery path where Git supports it. |
| Brand collision | Medium | Branchlight is a temporary codename only; perform trademark/domain review before public naming. |
| Research review sample bias | Medium | do not turn sparse old reviews into product statistics; validate with beta telemetry/interviews later. |

---

# 12. Development roadmap

## NOW: P0 core usable loop implemented

1. Research decisions frozen in this document.
2. Native Swift/XcodeGen project created.
3. `GitEngine` + CLI adapter implemented.
4. Porcelain parser, repository/worktree handling and real-Git integration tests implemented.
5. Shared status cache + aggregate status implemented.
6. Finder badge mapping remains cache-only.
7. Host app implements repository selection, automatic FSEvents refresh, diff, stage/unstage, commit, remote actions, branches and history.
8. Finder `Show Changes` and state-aware Stage/Unstage are forwarded as intents to the host.
9. Unsigned compile verification passes on Xcode 26.6 / Swift 6.

## NEXT: P0 signed Finder validation

1. configure a known Development Team/App Group provisioning path without changing Apple Developer Program resources implicitly
2. build/sign host + Finder extension locally
3. enable Branchlight Finder Sync in System Settings
4. verify real file/directory badges for modified, staged, untracked, renamed, deleted and conflict states
5. verify Finder `Show Changes`, Stage and Unstage intent round-trip against a disposable local repository
6. verify monitored-root hot reload and host FSEvents cache refresh while Finder is open
7. verify explicit limitation/fallback behavior for a File Provider-managed root
8. capture latency/CPU observations for a medium/large repository before declaring P0 daily-usable

## LATER

P1/P2/P3 items above, ordered by actual beta friction rather than feature-count vanity.

## HOLD

- App Store architecture
- hosted OAuth integrations
- AI provider selection
- plugin architecture
- custom design system

## DROP

- Electron
- custom Git implementation
- synchronous Git commands from Finder badge callbacks
- reproducing GitFinder’s UI/assets/text/code
- “all Git operations in Finder menu” as a goal

---

# Source register

## GitFinder primary sources

1. GitFinder product site: https://gitfinder.com/
2. GitFinder Release Notes: https://gitfinder.com/release-notes
3. GitFinder Support: https://gitfinder.com/support
4. Why GitFinder: https://gitfinder.com/blog/why-gitfinder/34

## Independent GitFinder/user sources

5. MacUpdate GitFinder: https://www.macupdate.com/app/mac/60013/gitfinder
6. XenForo community GitFinder thread: https://xenforo.com/community/threads/macos-gitfinder-git-integration-with-finder.143788/
7. AlternativeTo GitFinder: https://alternativeto.net/software/gitfinder/about/

Note: Reddit/Hacker News/Stack Overflow/Japanese review/YouTube searches were attempted. Public indexed material specific enough to support current GitFinder claims was sparse; unsupported claims were not filled in from guesswork.

## Apple primary sources

8. Finder Sync framework: https://developer.apple.com/documentation/FinderSync
9. Finder Sync App Extension Programming Guide: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html
10. macOS App Sandbox file access: https://developer.apple.com/documentation/Security/accessing-files-from-the-macos-app-sandbox
11. macOS Tahoe 26 Release Notes: https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes

## Competitor primary sources

12. Fork: https://git-fork.com/
13. Fork Release Notes: https://git-fork.com/releasenotes
14. Tower features: https://www.git-tower.com/features/all-features
15. Tower 17: https://www.git-tower.com/blog/tower-mac-17
16. Sublime Merge: https://www.sublimemerge.com/
17. GitHub Desktop docs: https://docs.github.com/en/desktop
18. Sourcetree: https://sourcetreeapp.com/sourcetreeapp
19. SmartGit features: https://www.smartgit.dev/features/

## Git engine/license primary sources

20. libgit2: https://libgit2.org/
21. SwiftGit2: https://github.com/SwiftGit2/SwiftGit2
22. Git: https://git-scm.com/about.html

---

# Research confidence summary

**Confirmed:** GitFinder’s major feature surface; Finder Sync public capabilities/lifecycle/performance guidance; GitFinder File Provider limitation; current competitor feature directions; P0 development environment; libgit2/SwiftGit2 public license statements.

**Inference:** GitFinder’s slower relative release cadence is a competitive opportunity; a persistent native host workflow would address sparse user complaints; CLI-first is the fastest correctness path for a direct-distribution P0.

**Unconfirmed:** GitFinder private architecture/cache/IPC, dedicated Quick Look integration, broad current user-sentiment frequencies, App Store viability of the final CLI-backed service design. These must not be represented as facts until separately verified.
