# Branchlight

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md"><strong>日本語</strong></a>
</p>

<p align="center">
  <strong>Gitを、Finderの中へ。</strong>
</p>

<p align="center">
  Branchlightは、Gitの状態確認、Stage / Unstage、インタラクティブDiff、履歴、Blame、Stash、Branch、Worktree、Remote操作までを、普段のFinder中心のファイル操作へ自然に組み込むmacOSネイティブGitクライアントです。
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/uniplanck/Branchlight/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/uniplanck/Branchlight/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="Status Alpha" src="https://img.shields.io/badge/status-alpha-orange">
</p>

---

## Branchlightは何を変えるのか

多くのGitクライアントは、Gitを操作するために「いま作業している場所」から離れることを要求します。

Finderでファイルを見つける。変更に気づく。Gitクライアントを開く。もう一度Repositoryを探す。もう一度そのファイルを探す。Diffを開く。そしてようやくStageやCommitを行う。

この往復は当たり前のように受け入れられていますが、本質的にはかなり不自然です。

Branchlightはその前提を逆転させます。

**Finderを作業の中心に残したまま、Gitの情報と操作をそこへ持ってくる。**

ファイルが存在する場所で状態を確認し、いまFinderで選択しているファイルやフォルダに対してGit操作を行い、より深い作業が必要になったときだけコンパクトなネイティブUIへ移る。Branchlightが目指しているのは、この流れです。

これは単に`git status`の結果へFinder用の見た目を被せただけのツールではありません。Finder Sync Extensionの制約、Gitの実際のsemantics、macOSのFile Providerとの競合、Repository監視、部分Stageなどを前提に、**Finder-native Git clientとして最初から設計したアーキテクチャ**です。

## いま何ができるのか

Branchlightには、すでに次の機能があります。

- Finder上のGit status badge
- Finder右クリックからの **Show Changes**
- Finder右クリックからの **Stage Selected / Unstage Selected**
- 単一ファイル、フォルダ、複数選択、Repository rootのselection planning
- 構造化されたInteractive Diff
- Hunk単位のStage / Unstage
- **選択した変更行だけをStage**
- Commit
- Fetch
- Push
- **fast-forward-only Pull**
- Branch一覧とBranch切り替え
- Repository全体の履歴
- 選択ファイルだけの履歴
- 行単位のBlame
- StashのCreate / Apply / Pop / Drop
- Worktreeの一覧 / 作成 / 削除
- detached HEAD認識
- linked worktree認識
- 最初のCommit前のRepositoryへの対応
- FSEventsベースの自動refresh
- File Provider環境の警告
- Finder callback内で重いGit処理を行わないcache-only Finder Extension

現在の自動テストは、Unit testと実際の一時Git Repositoryを使うIntegration testを合わせて**33本すべてPASS**しています。

## 何が普通のGitクライアントと違うのか

| 操作 | 一般的なDesktop Git Client | Branchlight |
| --- | --- | --- |
| 変更ファイルを見つける | Gitアプリを開いてRepositoryを探す | Finder上でそのまま確認 |
| Finderで選んだファイルをStage | Gitアプリで同じファイルを探し直す | Finderのcontext menuからStage |
| Diffを見る | Gitアプリへ完全に移動 | 選択中の変更からBranchlightへ直行 |
| 一部だけStage | クライアント独自UIに依存 | Hunk / 選択行Stageを構造化Diffで実行 |
| File History / Blame | Repository viewを辿る | いま選んでいるファイルをそのまま調査 |
| Finder統合 | ないことが多い | 製品の中心的なsurface |
| Finder Extensionの安全性 | 対象外 | callbackはcache-only |
| Repository refresh | アプリ中心のpolling / watcher | Host側FSEvents + shared snapshot |

Branchlightは**Finder-first**ですが、Finder-onlyではありません。

複雑なDiff、History、Blame、Stash、Worktree管理までをFinderの小さなcontext menuへ押し込めるのは、統合ではなく罰ゲームです。深いGit操作は適切なサイズのネイティブUIで行い、Finderは「いま見ているファイルからGitへ入る入口」として使います。

## Finderを重くしないための設計

Finder Sync Extensionの中で毎回`git status`を起動する設計は、一見簡単ですが、Finderのresponsivenessを犠牲にしやすい構造です。

Branchlightでは、この一点を明確なarchitecture invariantにしています。

> **Finder Extensionはcached stateを読む。Badge callbackからfull Git operationを実行しない。**

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

実際のGit executionとRepository refreshはHost側が所有します。Finder Extension側は、事前に作られたstatus snapshotを安価に参照するだけです。

共有境界には**App Group container内のatomic JSON file**を使っています。以前のApp Group preferences形式からのmigrationも実装済みです。

これにより、Finderのbadge表示を同期的な`CFPreferences`通信やGit subprocess起動へ依存させずに済みます。

## Interactive Staging

BranchlightはDiffを単なる文字列の塊として扱いません。

Git diffを、File、Hunk、Lineへ構造化して解析します。

そのため、Stage操作にも段階があります。

### Hunk全体をStage

変更Hunkを選択し、その単位でStageできます。

### 選択した変更行だけをStage

Branchlightは選択された変更から有効なPatchを再構築します。

必要なcontext lineを残し、Hunk rangeを再計算し、Gitが解釈できるPatchとしてindexへapplyします。

つまりUI上だけで「一部Stageしたことにする」のではなく、**実際のGit patch semanticsへ落とし込んでいる**のが重要な点です。

## Stash / History / Blame / Worktree

Branchlightは、Finder badgeと数個の右クリック項目だけで終わるprototypeではありません。

### Stash

Working Treeの状態をStashとして保存できます。

必要であればuntracked fileも含められ、その後Apply / Pop / DropまでネイティブUIから実行できます。

### File History

History画面ではRepository全体だけでなく、**選択中の1ファイルだけの履歴**へ切り替えられます。

### Blame

ファイルを別の画面で探し直すことなく、行単位のCommit attributionを確認できます。

Commit済みの行だけでなく、未Commitの行を含む状態も扱います。

### Worktree

現在のWorktreeを一覧し、任意の場所に新しいWorktreeとBranchを作成し、開き、不要になったものを安全に削除できます。

## 安全側に倒したGit操作

Branchlightは、便利さのためにGit Repositoryを勝手に危険な状態へ持っていく設計を避けています。

代表例は次の通りです。

- Pullは`git pull --ff-only`
- Working Treeに変更がある状態でのBranch switchには警告
- Stashの破棄は確認あり
- Worktree削除は確認あり
- Finderの複数選択はRepository境界を確認してから処理
- 複数RepositoryをまたぐFinder selectionは拒否
- `HEAD`がまだ存在しない最初のCommit前でもUnstage可能

Git GUIは「便利だから押したら履歴が書き換わっていた」という種類の親切を発揮しがちです。Branchlightでは、破壊的・重大な状態変更ほど明示的であることを優先します。

## Repositoryのedge caseも扱う

Status engineは、単純なModified / Cleanだけを見ているわけではありません。

- modified
- staged
- added
- deleted
- renamed
- untracked
- conflict
- nested repository
- detached `HEAD`
- linked worktree
- first commit前のrepository

を認識します。

Folder badgeでは、配下に存在するchanged descendantの状態を集約します。

そのためFinder上でフォルダを見ただけでも、その配下にGit上の変更が存在することを伝えられます。それでもitemごとにGitを起動する必要はありません。

## File Providerについて

macOSでは、iCloud Drive、Dropbox、OneDrive、Google DriveなどのFile Provider integrationがFinder Sync Extensionより優先される場合があります。

この場合、Finderの一部surfaceでBranchlightのbadgeやmenuが期待通り表示されない可能性があります。

Branchlightはこの制約を無視して「完全対応」とは言いません。

File Provider管理下と考えられるpathを検知した場合は警告します。

これはGitの制約ではなく、macOS側のExtension priorityに由来する制約です。

## 現在の状態

Branchlightは現在 **v0.1.0 alpha** です。

Core implementationに加え、local signed runtimeでは実際のFinderとGit Repositoryを使って次のflowを検証しています。

- Finder selectionからStage / Unstage
- Interactive Diff navigation
- Stash save / pop round trip
- File History
- committed / uncommitted lineを含むBlame
- Worktree create / remove
- Window close / reopen lifecycle
- App Group cache persistence
- legacy cache migration

現時点では**source-first**で公開しています。

誰でもそのままdownloadして使えるDeveloper ID signed + notarized binaryは、まだ一般配布していません。

## Quick Start

### 必要環境

- macOS 13以降
- Swift 6を扱えるXcode
- `/usr/bin/git`

生成済みの`Branchlight.xcodeproj`をRepositoryへ含めているため、**buildするだけならXcodeGenは不要**です。

`project.yml`は、Xcode projectを再生成したいContributor向けに残しています。

署名を含む詳しい手順は[docs/BUILDING.md](docs/BUILDING.md)を参照してください。

### 1. Clone

```bash
git clone https://github.com/uniplanck/Branchlight.git
cd Branchlight
```

### 2. Apple署名なしでCoreとTestを確認

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

これが最も簡単な確認方法です。

Apple Developer TeamやApp Groupを用意しなくても、Core buildとtest suiteを実行できます。

### 3. Finder Integrationを実際に動かす

Finder Sync ExtensionとApp Group通信には、local signed buildが必要です。

1. `Branchlight.xcodeproj`をXcodeで開く
2. `Branchlight`と`BranchlightFinderExtension`の両Targetで自分のDevelopment Teamを選択
3. 必要であればBundle Identifierを自分のTeam配下へ変更
4. 自分のTeamでApp Groupを作成し、両Targetへ有効化
5. 2つのentitlement fileにある`group.com.uniplanck.branchlight`を自分のApp Group identifierへ変更
6. BranchlightをBuild & Run
7. macOSが自動で有効化しない場合はSystem Settingsから**Branchlight Finder Extension**を有効化
8. BranchlightでGit Repositoryを選択

Extensionが有効になれば、FinderはBranchlightが作成したcached repository stateを参照し、監視対象Repositoryでbadgeやcontext actionを表示できます。

> ArchitectureやGit Engine、UIだけを調べたい場合、最初からFinder Extensionを設定する必要はありません。

## Build Verification

Buildのみ:

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

全Test:

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Project Layout

```text
BranchlightCore/
  Git engine, status parser, diff parser / patch builder,
  shared cache, repository models, selection planner, service boundary

BranchlightHost/
  SwiftUI / AppKit host application, repository watcher,
  interactive Git UI, Finder intent handling

BranchlightFinderExtension/
  軽量Finder Sync Extension: badge, menu, cached state, intent forwarding

BranchlightCoreTests/
  Unit test + real temporary Git repository integration test

project.yml
  XcodeGen project definition

docs/research/
  Product / architecture research
```

## Testing Philosophy

BranchlightはGit behaviorをmock outputだけで検証しません。

**実際に一時Git Repositoryを作成し、そのRepositoryへGit操作を行うIntegration test**を重視しています。

Test suiteには次のscenarioが含まれます。

- status classification
- rename / deletion
- conflict
- stage / unstage / diff / commit / history
- selected-line patch staging
- whole-hunk staging / unstaging
- clean repository
- first commit前のrepository
- nested repository
- detached HEAD
- linked worktree
- local bare remoteを使ったfetch / pull / push
- stash lifecycle
- file history / blame
- worktree lifecycle
- shared cache persistence / legacy migration
- Finder selection planning

Git wrapperは、正常系だけなら驚くほど簡単に作れます。

問題が出るのは、その「簡単なwrapper」が想定をやめた場所です。Branchlightはそのedge caseを最初からtest対象へ含めています。

## Design Principles

### 1. Finderをfirst-class surfaceとして扱う

Finder integrationは、普通のdesktop Git GUIの横に付けたlauncher buttonではありません。

Branchlightという製品の中心的なsurfaceです。

### 2. Finder Extensionを薄く保つ

`requestBadgeIdentifier(for:)`からfull `git status`を実行しません。

重いGit subprocess lifecycleをFinder processへ所有させません。

### 3. 実際のGit semanticsを使う

Branchlightは`GitService`境界の向こうでsystem Gitを使います。

UI専用の「Gitっぽい別世界」を作り、本物のRepository stateと乖離させることを避けます。

### 4. 危険な操作を明示する

Stateを破壊したり大きく書き換えたりする操作は、見えること、確認できることを優先します。

### 5. 将来のArchitecture upgradeを塞がない

UIはprocess launch detailではなく`GitService`へ依存します。

現在はin-process serviceですが、この境界により将来的なdurable XPC / single Git service構成へ移行できる余地を残しています。

## Roadmap

Finder Extensionを肥大化させず、より深いGit workflowへ拡張できるように設計しています。

今後の候補には次があります。

- durable XPC / single Git service
- Merge workflow
- Rebase workflow
- Conflict Resolver
- より詳細なCommit view
- Tags
- Upstream / Ahead / Behind visualization
- Submodule
- Git LFS
- GitHub / GitLab integration
- Developer ID signed + notarized GitHub Release

## Contributing

Contributionは歓迎します。

Finder boundaryやGit execution modelを変更する前に、[CONTRIBUTING.md](CONTRIBUTING.md)を確認してください。

Branchlightには、Finderをresponsiveかつpredictableに保つため、意図的に守っているarchitecture invariantがあります。

特に歓迎するものは次です。

- 再現可能なBug Report
- Gitのedge case
- Finder Sync Extensionの実機挙動レポート
- scopeが明確なPull Request

## License

Branchlightは[MIT License](LICENSE)で公開しています。

利用、学習、Fork、改良、派生開発、商用利用もMIT Licenseの範囲で可能です。

ソフトウェアの substantial copyにはLicense noticeを保持してください。

---

<p align="center">
  <strong>Branchlightは、Gitを「開きに行く場所」ではなく、ファイルシステムの一部へ近づけます。</strong>
</p>
