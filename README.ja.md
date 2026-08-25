# Branchlight

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md"><strong>日本語</strong></a>
</p>

<p align="center">
  <strong>Gitを、Finderの中へ。</strong>
</p>

<p align="center">
  Branchlightは、Gitの状態確認、Stage / Unstage、Interactive Diff、History、Blame、Stash、Branch、Worktree、Remote操作までを、普段のFinder中心のファイル操作へ直接つなぐmacOSネイティブGitクライアントです。
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/uniplanck/Branchlight/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/uniplanck/Branchlight/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="Status Alpha" src="https://img.shields.io/badge/status-alpha-orange">
</p>

---

## Gitクライアントを開く前に、もうファイルはFinderにある

Gitを使うとき、多くのデスクトップクライアントは一度作業場所を離れることを要求します。

Finderでファイルを見つける。変更に気づく。Gitクライアントを開く。Repositoryを探し直す。同じファイルを探し直す。Diffを確認する。そしてようやくStageやCommitを行う。

一つひとつは小さな操作です。それでも、この往復は開発中に何度も発生します。

Branchlightが変えたいのは、Gitそのものではありません。**Gitへ入るまでの距離です。**

Finderにあるファイルは、そのままGit操作の入口になります。変更状態はファイルが見えている場所で確認でき、Finderで選択しているファイルやフォルダへStage / Unstageを実行できる。より深いDiff、History、Blame、Stash、Branch、Worktree操作が必要になったときだけ、BranchlightのコンパクトなネイティブUIへ移ります。

**Finderは作業の中心に残る。Gitは、その周囲に自然に現れる。**

Branchlightは、この考え方をFinder Sync Extension、Gitの実際のsemantics、Repository監視、部分Stage、App Group共有境界まで含めて実装したFinder-native Git clientです。単に`git status`へFinder風の見た目を被せたツールではありません。

## いま、どこまでできるのか

Branchlightはすでに、Finder badgeと数個の右クリック項目だけのprototypeを超えています。

現在利用できる主な機能は次の通りです。

- shared cacheに基づくFinderのGit status badge
- Finder右クリックの **Show Changes**
- Finder右クリックの **Stage Selected / Unstage Selected**
- 単一ファイル、フォルダ、複数選択、Repository rootを扱うselection planning
- 構造化されたInteractive Diff
- Hunk単位のStage / Unstage
- **選択した変更行だけをStageするselected-line staging**
- Commit workflow
- Fetch / Push / **fast-forward-only Pull**
- Branch一覧とBranch切り替え
- Repository History
- 選択ファイルだけのFile History
- 行単位のBlame
- StashのCreate / Apply / Pop / Drop
- Worktreeの一覧 / 作成 / 削除
- detached `HEAD`の認識
- linked worktreeの認識
- 最初のCommit前のRepositoryへの対応
- FSEventsによるbackground refresh
- Finder / File Provider競合への警告
- badge callbackからfull Git operationを実行しないcache-only Finder Extension

現在の自動テストは、Unit testと実際の一時Git Repositoryを使うIntegration testを合わせて**33本すべてPASS**しています。

機能数だけが重要なのではありません。Finderから始まった操作が、Gitのindex、patch、branch、stash、worktreeといった本物の状態へどう到達するかまで、一つのGitクライアントとしてつながっています。

## 一般的なGitクライアントとの違い

| Workflow | 一般的なDesktop Git Client | Branchlight |
| --- | --- | --- |
| 変更ファイルを見つける | Gitアプリを開きRepositoryを探す | Finder上でそのまま確認 |
| Finderで選んだファイルをStage | Gitアプリで同じファイルを探し直す | Finderのcontext menuからStage |
| Patchを確認 | Gitアプリへ移動して対象を探す | 現在の変更からBranchlightへ直行 |
| 一部分だけStage | クライアント固有のstaging UIに依存 | Hunk / selected-line staging |
| File History / Blame | Repository viewを辿る | いま選択しているファイルをそのまま調査 |
| Finder統合 | ないことが多い | 製品の中心的なsurface |
| Extensionの安全性 | 対象外 | Finder callbackはcache-only |
| Repository refresh | アプリ中心のpolling / watcher | Host側FSEvents + shared snapshot |

Branchlightは**Finder-first**です。ただし、Finder-onlyではありません。

Diff、History、Blame、Stash、WorktreeまでをFinderの小さなcontext menuへ押し込めても、操作が窮屈になるだけです。Finderは「いま見ているファイルからGitへ入る場所」として使い、情報量の多い操作は適切なサイズのネイティブUIへ渡す。この分担がBranchlightの基本設計です。

## Finder-nativeだからこそ、Finderを重くしない

Finderへ深く統合するほど、実装側には慎重さが必要になります。

Finder Sync Extensionのbadge callbackから毎回`git status`を起動すれば、実装自体は分かりやすく見えます。しかしFinderは、Gitクライアントのためだけに動くプロセスではありません。ファイルを表示するたびに重いGit処理へ巻き込む設計は、統合の便利さと引き換えにFinder自体のresponsivenessを損なう可能性があります。

Branchlightは、ここに明確な境界を置いています。

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

Git executionとRepository refreshを所有するのはHost側です。Finder Extensionは、Hostが事前に作ったstatus snapshotを安価に参照し、badgeやfolder aggregationへ使います。

この分離によって、FinderはGit subprocessの実行場所ではなく、**Gitの状態を受け取る軽い表示・操作surface**でいられます。

共有境界には、App Group container内の**atomic JSON file**を使っています。以前使っていたApp Group preferences形式からのmigrationも実装済みです。

これは単なる保存形式の好みではありません。Finder側のstatus deliveryを同期的な`CFPreferences`通信へ依存させず、共有cacheをファイル境界として明確にするための設計です。

## Diffは表示するだけではなく、Gitのindexへ届く

部分Stageは、Git GUIの完成度が表れやすい操作です。

Diffを単なる色付きテキストとして表示するだけなら簡単です。しかし「このHunkだけ」「この変更行だけ」をStageするには、UI上の選択をGitが受け取れるpatchへ戻さなければなりません。

BranchlightはGit diffを、File、Hunk、Lineへ構造化して解析します。

### Hunk全体をStage / Unstage

Hunkを選択し、その単位でindexへ反映できます。

### 選択した変更行だけをStage

selected-line stagingでは、選択された変更だけから有効なpatchを再構築します。

必要なcontextを残し、Hunk rangeを再計算し、Gitが解釈できるpatchとしてindexへapplyします。

つまり、BranchlightのUI内部だけに「一部Stage済み」という別の状態を作るのではありません。**最終的な状態は本物のGit indexに存在します。**

この設計は、UIの都合でGitと別の世界を作らないために重要です。BranchlightはGitを置き換えるのではなく、GitのsemanticsへFinderから自然に到達するためのUIを作っています。

## Stash、History、Blame、Worktreeまで、同じ流れの中にある

Finderで変更を見つけたあと、必要になる作業はStageだけとは限りません。

変更を一時退避したいこともあれば、そのファイルがいつ変わったのか知りたいこともある。特定の行を書いたCommitを確認したいことも、別Branchを並行して扱うためにWorktreeを作りたいこともあります。

Branchlightでは、それらを同じRepository workflowの中で扱えます。

### Stash

Working Treeの状態をStashとして保存できます。

必要に応じてuntracked fileも含められ、保存後はApply / Pop / DropまでネイティブUIから操作できます。

### File History

History画面はRepository全体だけでなく、**現在選択している1ファイルだけの履歴**へ切り替えられます。

Finderで対象を見つけたあと、履歴を見るために別のRepository treeを最初から辿り直す必要はありません。

### Blame

選択ファイルのline-level commit attributionを表示します。

Commit済みの行だけでなく、まだCommitされていない行を含む状態も扱います。

### Worktree

現在のWorktreeを一覧し、任意の場所へ新しいWorktreeとBranchを作成し、開き、不要になったWorktreeを削除できます。

BranchlightではWorktreeも「高度なGit機能だから別画面の奥へ隠す」のではなく、Branch workflowの延長として扱います。

## 便利さより先に、壊しにくさを置く

Gitクライアントは操作を簡単にできます。それは利点ですが、簡単にした操作がRepositoryの履歴やWorking Treeを大きく変える場合、UI側には別の責任が生まれます。

Branchlightは、重大な状態変更ほど明示的に扱います。

代表的な挙動は次の通りです。

- Pullは`git pull --ff-only`
- Working Treeに変更がある状態でのBranch switchには警告
- Stashの破棄は確認あり
- Worktree削除は確認あり
- Finderの複数選択はRepository境界を確認してから処理
- 複数RepositoryをまたぐFinder selectionは拒否
- `HEAD`がまだ存在しないfirst commit前のRepositoryでもUnstage可能

Branchlightが目指しているのは、Gitを「何でもワンクリックで実行できるもの」にすることではありません。**頻繁な操作は近くし、危険な操作は見えるようにすること**です。

## Gitの“普通ではない状態”も、普通に起こる

実際のRepositoryは、きれいなModified / Cleanの二択では動きません。

Status engineは次の状態を認識します。

- modified
- staged
- added
- deleted
- renamed
- untracked
- conflicts
- nested repositories
- detached `HEAD`
- linked worktrees
- first commit前のrepository

Folder badgeでは、配下のchanged descendantを集約します。

そのため、Finderでフォルダを見ている段階でも、内部にGit上の変更が存在することを把握できます。それでもitemごとにGitを起動する必要はありません。Hostが作ったsnapshotから、Finderに必要な情報だけを返します。

## File Providerには、macOS側の優先順位がある

Finderへ統合するアプリが避けて通れない制約もあります。

macOSでは、iCloud Drive、Dropbox、OneDrive、Google DriveなどのFile Provider integrationが、Finder Sync Extensionより優先される場合があります。その結果、一部のFinder surfaceでBranchlightのbadgeやmenuが期待通り表示されない可能性があります。

Branchlightは、この制約を隠して「どこでも完全に動く」とは扱いません。

File Provider管理下と考えられるrootを検知した場合は警告します。

これはGitの制約ではなく、macOSのExtension priorityに由来する制約です。BranchlightがFinder-nativeである以上、OSが定める境界も製品仕様の一部として扱います。

## 現在の状態: v0.1.0 alpha

Branchlightは現在 **v0.1.0 alpha** です。

Core implementationだけでなく、local signed runtimeでは実際のFinderとGit Repositoryを使って次のflowを検証しています。

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

誰でもdownloadしてそのまま実行できるDeveloper ID signed + notarized binaryは、まだ一般配布していません。

これは、GitHubにあるコードが未検証という意味ではありません。Coreの自動テストに加え、開発用署名を使ったFinder実機flowまで確認したうえで、配布形態だけをsource-firstに留めている状態です。

## Quick Start

### 必要環境

- macOS 13以降
- Swift 6を扱えるXcode
- `/usr/bin/git`

生成済みの`Branchlight.xcodeproj`をRepositoryへ含めているため、**buildするだけならXcodeGenは不要**です。

`project.yml`も同梱しているので、Projectを再生成したいContributorはXcodeGenを使えます。署名を含む詳細なbuild手順は[docs/BUILDING.md](docs/BUILDING.md)を参照してください。

### 1. Clone

```bash
git clone https://github.com/uniplanck/Branchlight.git
cd Branchlight
```

### 2. Apple署名なしでCoreとTestを確認する

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Finder Extensionを設定しなくても、まずCoreをbuildし、test suiteを実行できます。

「コードを読みたい」「Git engineやUIへContributionしたい」という場合は、ここから始めるのが最短です。

### 3. Finder integrationを実際に動かす

Finder SyncとApp Group communicationを使うには、local signingが必要です。

1. `Branchlight.xcodeproj`をXcodeで開きます。
2. `Branchlight`と`BranchlightFinderExtension`の両targetで、自分のDevelopment Teamを選択します。
3. 必要に応じてapp / extensionのbundle identifierを、自分のTeamで所有できる値へ変更します。
4. 自分のTeamでApp Groupを作成し、両targetに有効化します。
5. 2つのentitlement fileにある`group.com.uniplanck.branchlight`を、自分のApp Group identifierへ変更します。
6. `Branchlight`をBuild & Runします。
7. macOSが自動で有効化しない場合、System Settingsから**Branchlight Finder Extension**を有効にします。設定場所はmacOSのversionによって異なります。
8. BranchlightでGit Repositoryを選択します。

Extensionが有効になると、FinderはBranchlightのcached repository stateを参照し、監視対象RepositoryでbadgeやBranchlight actionを表示できます。

> Architectureの調査、Git engine、Diff、UIの開発だけが目的なら、最初からFinder Extensionを設定する必要はありません。

## Build verification

Buildだけを確認する場合:

```bash
xcodebuild \
  -project Branchlight.xcodeproj \
  -scheme Branchlight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

全testを実行する場合:

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

この分割で重要なのは、Finder ExtensionとGit executionを同じ場所へ置いていないことです。

UIも直接process launchの詳細へ依存せず、`GitService`を境界としてGit engineへ接続します。現在はin-process serviceですが、この境界は将来的なdurable XPC / single Git serviceへ発展させられる構造になっています。

## Testはmockだけで終わらせない

Git wrapperのtestは、command文字列が期待通り生成されたことだけを確認しても十分ではありません。

本当に厄介なのは、Repositoryが実際にその状態になったときです。

Branchlightではmocked command outputだけでなく、**実際の一時Git Repositoryを作ってIntegration testを実行**します。

現在のsuiteは、次のscenarioを含みます。

- status classification
- rename / deletion
- conflicts
- stage / unstage / diff / commit / history
- selected-line patch staging
- whole-hunk staging / unstaging
- clean repository
- first commit前のrepository
- nested repository
- detached `HEAD`
- linked worktree
- local bare remoteを使ったfetch / pull / push
- stash lifecycle
- file history / blame
- worktree lifecycle
- shared cache persistence / legacy migration
- Finder selection planning

Gitのedge caseは、簡単なwrapperがtestをやめた場所から出てきます。

だからBranchlightでは、「Git commandを呼べた」ではなく、**その結果としてRepositoryがどう変化したか**をtest対象にしています。

## Design Principles

### 1. Finderをfirst-class surfaceとして扱う

Finder integrationは、Desktop Git GUIへ移動するためのlauncher buttonではありません。

ファイルの状態確認と選択操作は、Finderそのものが製品surfaceです。

### 2. Extensionは薄く保つ

`requestBadgeIdentifier(for:)`からfull `git status`を実行しません。

Finderにheavy Git subprocess lifecycleを所有させません。

### 3. 本物のGit semanticsを使う

Branchlightはsystem Git engineをservice boundaryの後ろで利用します。

UI用に別の“Git風state”を作り、実Repositoryと乖離させる設計は避けます。

### 4. 危険な操作ほど明示する

Stateを破壊したり大きく書き換えたりする操作は、見える形で確認できることを優先します。

### 5. いまの実装で将来を塞がない

UIはprocess launchの詳細ではなく`GitService`へ依存します。

現在のimplementationはin-process serviceですが、この境界は将来的なdurable XPC / single Git serviceへ拡張できる余地を残しています。

## Roadmap

Branchlightは、Finder Extensionを重くせずにGit workflowを深くしていく方向で設計されています。

今後の候補には次があります。

- durable XPC / single Git service
- Merge / Rebase workflow
- Conflict Resolver
- より詳細なCommit view
- Tags
- upstream / ahead / behind visualization
- Submodule / Git LFS
- GitHub / GitLabなどhosted serviceとのintegration
- Developer ID signed + notarized GitHub Releases

Roadmapにある機能は、現在実装済みの機能としては扱っていません。Branchlightの現在地はv0.1.0 alphaであり、Finder-first architectureを維持したまま次のGit workflowへ広げていく段階です。

## Contributing

Contributionを歓迎します。

Finder boundaryやGit execution modelを変更する前に、[CONTRIBUTING.md](CONTRIBUTING.md)を確認してください。Branchlightには、Finderのresponsivenessと予測可能性を守るために意図的に維持しているarchitecture invariantがあります。

特に価値があるのは、再現可能なGit edge case、Finder Syncの挙動報告、具体的なBug Report、scopeの明確なPull Requestです。

## License

Branchlightは[MIT License](LICENSE)で公開しています。

使う、読む、forkする、改良する、自分のアイデアへ組み込む。MIT Licenseの範囲で自由に利用できます。Softwareの実質的なcopyへはLicense noticeを保持してください。

---

<p align="center">
  <strong>Branchlightは、Gitを「開きに行くアプリ」から、ファイルシステムのすぐそばにある道具へ変えていきます。</strong>
</p>
