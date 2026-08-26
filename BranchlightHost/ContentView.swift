import BranchlightCore
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = 0
    @State private var branchToSwitch = ""
    @State private var branchToMerge = ""
    @State private var branchToRebaseOnto = ""
    @State private var showBranchConfirmation = false
    @State private var showMergeConfirmation = false
    @State private var showRebaseConfirmation = false
    @State private var showPullConfirmation = false
    @State private var showStashes = true
    @State private var historyMode: HistoryMode = .repository
    @State private var stashToDrop: GitStashEntry?
    @State private var worktreeToRemove: GitWorktree?
    @State private var commitToCherryPick: GitCommit?
    @State private var commitToRevert: GitCommit?
    @State private var inspectedCommit: GitCommit?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if let snapshot = model.snapshot {
                repositoryBar(snapshot)
                if let warning = model.finderIntegrationWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TabView(selection: $selectedTab) {
                    changesView(snapshot)
                        .tabItem { Label("Changes", systemImage: "pencil.and.list.clipboard") }
                        .tag(0)
                    diffView
                        .tabItem { Label("Diff", systemImage: "doc.text.magnifyingglass") }
                        .tag(1)
                    historyView
                        .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                        .tag(2)
                    branchesView
                        .tabItem { Label("Branches", systemImage: "point.3.connected.trianglepath.dotted") }
                        .tag(3)
                    conflictView
                        .tabItem {
                            Label(
                                "Conflicts",
                                systemImage: model.conflictedPaths.isEmpty ? "checkmark.shield" : "exclamationmark.triangle"
                            )
                        }
                        .tag(4)
                }
            } else {
                emptyState
            }

            statusFooter
        }
        .padding(20)
        .onReceive(model.$requestedTab.compactMap { $0 }) { requestedTab in
            if selectedTab != requestedTab {
                selectedTab = requestedTab
            }
        }
        .alert("Switch branch?", isPresented: $showBranchConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Switch") {
                model.switchBranch(to: branchToSwitch)
            }
        } message: {
            Text(model.snapshot?.isClean == false
                 ? "The working tree has changes. Git will refuse unsafe switches, but review your changes before continuing."
                 : "Switch to \(branchToSwitch)?")
        }
        .alert("Merge branch?", isPresented: $showMergeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Merge") {
                model.mergeBranch(branchToMerge)
            }
        } message: {
            Text("Merge \(branchToMerge) into the current branch? If conflicts occur, Branchlight will keep the merge in progress so you can resolve or abort it safely.")
        }
        .alert("Rebase current branch?", isPresented: $showRebaseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Rebase") {
                model.rebaseCurrentBranch(onto: branchToRebaseOnto)
            }
        } message: {
            Text("Rebase the current branch onto \(branchToRebaseOnto)? This rewrites the current branch's local commits and may require conflict resolution.")
        }
        .alert("Pull remote changes?", isPresented: $showPullConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Pull") { model.pull() }
        } message: {
            Text("Branchlight uses git pull --ff-only. It will not create an automatic merge commit.")
        }
        .alert("Cherry-pick commit?", isPresented: Binding(
            get: { commitToCherryPick != nil },
            set: { if !$0 { commitToCherryPick = nil } }
        )) {
            Button("Cancel", role: .cancel) { commitToCherryPick = nil }
            Button("Cherry-pick") {
                if let commit = commitToCherryPick { model.cherryPick(commit) }
                commitToCherryPick = nil
            }
        } message: {
            if let commit = commitToCherryPick {
                Text("Apply \(commit.shortHash) “\(commit.subject)” onto the current branch? Conflicts will remain in progress for resolution in Branchlight.")
            }
        }
        .alert("Revert commit?", isPresented: Binding(
            get: { commitToRevert != nil },
            set: { if !$0 { commitToRevert = nil } }
        )) {
            Button("Cancel", role: .cancel) { commitToRevert = nil }
            Button("Revert") {
                if let commit = commitToRevert { model.revert(commit) }
                commitToRevert = nil
            }
        } message: {
            if let commit = commitToRevert {
                Text("Create a new commit that reverses \(commit.shortHash) “\(commit.subject)”? Existing history will not be rewritten.")
            }
        }
        .alert("Drop stash?", isPresented: Binding(
            get: { stashToDrop != nil },
            set: { if !$0 { stashToDrop = nil } }
        )) {
            Button("Cancel", role: .cancel) { stashToDrop = nil }
            Button("Drop", role: .destructive) {
                if let stash = stashToDrop { model.dropStash(stash) }
                stashToDrop = nil
            }
        } message: {
            Text(stashToDrop?.message ?? "This stash will be deleted.")
        }
        .alert("Remove worktree?", isPresented: Binding(
            get: { worktreeToRemove != nil },
            set: { if !$0 { worktreeToRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { worktreeToRemove = nil }
            Button("Remove", role: .destructive) {
                if let worktree = worktreeToRemove { model.removeWorktree(worktree) }
                worktreeToRemove = nil
            }
        } message: {
            Text(worktreeToRemove?.path ?? "The linked worktree directory will be removed by Git.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Branchlight")
                    .font(.title2.weight(.semibold))
                Text("Finder-native Git")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.monitoredRoots.isEmpty {
                repositoryRadarMenu
            }

            Button("Add Repository…") {
                model.chooseRepository()
            }

            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.repositoryURL == nil || model.isRefreshing)
        }
    }

    private var repositoryRadarMenu: some View {
        let envelope = SharedStatusCache()?.load() ?? StatusCacheEnvelope()
        return Menu("Radar") {
            ForEach(model.monitoredRoots, id: \.self) { root in
                Button(radarTitle(for: root, envelope: envelope)) {
                    model.openRepository(path: root)
                }
            }
        }
        .help("Repository Radar")
    }

    private func radarTitle(for root: String, envelope: StatusCacheEnvelope) -> String {
        let name = URL(fileURLWithPath: root).lastPathComponent
        guard let intelligence = envelope.intelligence(forRepositoryRoot: root) else {
            return name
        }

        var components = [name, intelligence.isDetachedHead ? "HEAD \(intelligence.branch)" : intelligence.branch]
        if let tracking = intelligence.tracking {
            components.append(tracking.summary)
        }
        if intelligence.operationMode != .normal {
            components.append(shortOperationName(intelligence.operationMode))
        }
        if intelligence.conflictCount > 0 {
            components.append("\(intelligence.conflictCount) conflict\(intelligence.conflictCount == 1 ? "" : "s")")
        } else if intelligence.changedCount > 0 {
            components.append("\(intelligence.changedCount) changed")
        } else {
            components.append("clean")
        }
        return components.joined(separator: "  •  ")
    }

    private func repositoryBar(_ snapshot: GitStatusSnapshot) -> some View {
        let intelligence = SharedStatusCache()?.load().intelligence(forRepositoryRoot: snapshot.repositoryRoot)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: snapshot.repositoryRoot).lastPathComponent)
                    .font(.headline)
                Text(snapshot.repositoryRoot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Label(
                    branchTitle(snapshot: snapshot, intelligence: intelligence),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(.callout.weight(.medium))

                if let intelligence, intelligence.operationMode != .normal {
                    Label(shortOperationName(intelligence.operationMode), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(intelligence.conflictCount > 0 ? .red : .secondary)
                }
            }

            Text(snapshot.summary)
                .font(.callout)
                .foregroundColor(snapshot.isClean ? .secondary : .primary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func branchTitle(snapshot: GitStatusSnapshot, intelligence: GitRepositoryIntelligence?) -> String {
        var title = snapshot.isDetachedHead ? "Detached @ \(snapshot.branch)" : snapshot.branch
        if let tracking = intelligence?.tracking {
            title += "  \(tracking.summary)"
        }
        return title
    }

    private func shortOperationName(_ mode: GitRepositoryOperationMode) -> String {
        switch mode {
        case .normal: return "Normal"
        case .merging: return "Merging"
        case .rebasing: return "Rebasing"
        case .cherryPicking: return "Cherry-picking"
        case .reverting: return "Reverting"
        case .bisecting: return "Bisecting"
        }
    }

    private var currentRepositoryIntelligence: GitRepositoryIntelligence? {
        guard let root = model.snapshot?.repositoryRoot else { return nil }
        return SharedStatusCache()?.load().intelligence(forRepositoryRoot: root)
    }

    private var hasGitOperationInProgress: Bool {
        currentRepositoryIntelligence?.operationMode != .normal
    }

    private func isControllableOperation(_ mode: GitRepositoryOperationMode) -> Bool {
        switch mode {
        case .merging, .rebasing, .cherryPicking, .reverting:
            return true
        case .normal, .bisecting:
            return false
        }
    }

    private func changesView(_ snapshot: GitStatusSnapshot) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button("Show Diff") {
                    model.loadDiff()
                    selectedTab = 1
                }
                .disabled(model.selectedPaths.isEmpty || model.isRefreshing)

                Button("Stage") { model.stageSelected() }
                    .disabled(!model.canStageSelection || model.isRefreshing)

                Button("Unstage") { model.unstageSelected() }
                    .disabled(!model.canUnstageSelection || model.isRefreshing)

                Spacer()

                Button("Fetch") { model.fetch() }
                    .disabled(model.isRefreshing)
                Button("Pull…") { showPullConfirmation = true }
                    .disabled(model.isRefreshing)
                Button("Push") { model.push() }
                    .disabled(model.isRefreshing)
            }

            GroupBox {
                if snapshot.paths.isEmpty {
                    Label("Working tree is clean", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    List(selection: $model.selectedPaths) {
                        ForEach(snapshot.paths, id: \.path) { status in
                            HStack(spacing: 10) {
                                Image(systemName: symbol(for: status.kind))
                                    .frame(width: 18)
                                Text(status.kind.rawValue.capitalized)
                                    .frame(width: 78, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                Text(status.isStaged ? "Staged" : "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .leading)
                                Text(status.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .tag(status.path)
                        }
                    }
                }
            } label: {
                Text("Working Tree")
            }

            HStack(spacing: 8) {
                TextField("Commit message", text: $model.commitMessage)
                    .textFieldStyle(.roundedBorder)
                Button("Commit") { model.commit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.hasStagedChanges || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRefreshing)
            }

            DisclosureGroup(isExpanded: $showStashes) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Optional stash message", text: $model.stashMessage)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Include untracked", isOn: $model.stashIncludeUntracked)
                            .toggleStyle(.checkbox)
                        Button("Save Stash") { model.createStash() }
                            .disabled(snapshot.isClean || model.isRefreshing)
                    }

                    if model.stashes.isEmpty {
                        Text("No stashes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.stashes) { stash in
                            HStack(spacing: 8) {
                                Text(stash.reference)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                Text(stash.message)
                                    .lineLimit(1)
                                Spacer()
                                Button("Apply") { model.applyStash(stash, pop: false) }
                                    .disabled(model.isRefreshing)
                                Button("Pop") { model.applyStash(stash, pop: true) }
                                    .disabled(model.isRefreshing)
                                Button("Drop…") { stashToDrop = stash }
                                    .disabled(model.isRefreshing)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Stashes (\(model.stashes.count))")
            }
        }
        .padding(.top, 8)
    }

    private var diffView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interactive Diff")
                        .font(.headline)
                    Text("Stage or unstage complete hunks, or select individual changed lines.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload Diff") { model.loadDiff() }
                    .disabled(model.repositoryURL == nil || model.isRefreshing)
            }

            if model.unstagedDiffFiles.isEmpty && model.stagedDiffFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No textual diff")
                        .font(.headline)
                    Text(model.diffText.isEmpty ? "Select changed files and load a diff." : model.diffText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !model.unstagedDiffFiles.isEmpty {
                            diffSection(title: "Unstaged", files: model.unstagedDiffFiles, staged: false)
                        }
                        if !model.stagedDiffFiles.isEmpty {
                            diffSection(title: "Staged", files: model.stagedDiffFiles, staged: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func diffSection(title: String, files: [GitDiffFile], staged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 8) {
                    Label(file.displayPath, systemImage: staged ? "checkmark.circle" : "pencil")
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)

                    ForEach(file.hunks) { hunk in
                        diffHunkCard(file: file, hunk: hunk, staged: staged)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func diffHunkCard(file: GitDiffFile, hunk: GitDiffHunk, staged: Bool) -> some View {
        let selectedLines = model.selectedLineOrdinals(file: file, hunk: hunk, staged: staged)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(hunk.header)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Spacer()

                Button(staged ? "Unstage Hunk" : "Stage Hunk") {
                    if staged {
                        model.unstageHunk(file: file, hunk: hunk)
                    } else {
                        model.stageHunk(file: file, hunk: hunk)
                    }
                }
                .disabled(model.isRefreshing)

                Button(staged ? "Unstage Selected Lines" : "Stage Selected Lines") {
                    if staged {
                        model.unstageSelectedLines(file: file, hunk: hunk)
                    } else {
                        model.stageSelectedLines(file: file, hunk: hunk)
                    }
                }
                .disabled(selectedLines.isEmpty || model.isRefreshing)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunk.lines) { line in
                    diffLineRow(file: file, hunk: hunk, line: line, staged: staged, selectedLines: selectedLines)
                }
            }
            .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func diffLineRow(
        file: GitDiffFile,
        hunk: GitDiffHunk,
        line: GitDiffLine,
        staged: Bool,
        selectedLines: Set<Int>
    ) -> some View {
        HStack(spacing: 6) {
            if line.isChange {
                Button {
                    model.toggleDiffLine(file: file, hunk: hunk, line: line, staged: staged)
                } label: {
                    Image(systemName: selectedLines.contains(line.ordinal) ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshing)
            } else {
                Color.clear.frame(width: 13, height: 13)
            }

            Text(line.oldLineNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newLineNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(.tertiary)

            Text(line.raw)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(diffLineBackground(line.kind))
    }

    private func diffLineBackground(_ kind: GitDiffLineKind) -> Color {
        switch kind {
        case .addition: return .green.opacity(0.12)
        case .deletion: return .red.opacity(0.12)
        case .context, .metadata: return .clear
        }
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("History scope", selection: $historyMode) {
                    ForEach(HistoryMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                if historyMode != .repository {
                    Text(model.selectedFilePath ?? "Select exactly one changed file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reload") { loadHistoryMode() }
                        .disabled(!model.canInspectSelectedFile || model.isRefreshing)
                }
            }

            if let intelligence = currentRepositoryIntelligence, isControllableOperation(intelligence.operationMode) {
                advancedOperationCard(intelligence)
            }

            if let inspectedCommit {
                commitDetailCard(inspectedCommit)
            }

            switch historyMode {
            case .repository:
                commitList(model.history, showMutationActions: true)
            case .file:
                if model.canInspectSelectedFile {
                    commitList(model.fileHistory, showMutationActions: false)
                } else {
                    historySelectionHint("Select one changed file in Changes, then return here for its history.")
                }
            case .blame:
                if model.canInspectSelectedFile {
                    blameList
                } else {
                    historySelectionHint("Select one changed file in Changes, then return here for blame.")
                }
            }
        }
        .padding(.top, 8)
        .onChange(of: historyMode) { _ in
            inspectedCommit = nil
            loadHistoryMode()
        }
    }

    private func commitList(_ commits: [GitCommit], showMutationActions: Bool) -> some View {
        List(commits) { commit in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(commit.shortHash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(commit.author)
                        if let date = commit.authoredAt {
                            Text("·")
                            Text(date, style: .relative)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Details") { inspectedCommit = commit }
                if showMutationActions {
                    Button("Cherry-pick…") { commitToCherryPick = commit }
                        .disabled(model.isRefreshing || hasGitOperationInProgress)
                    Button("Revert…") { commitToRevert = commit }
                        .disabled(model.isRefreshing || hasGitOperationInProgress)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func commitDetailCard(_ commit: GitCommit) -> some View {
        GroupBox("Commit Detail") {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(commit.subject)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(commit.author)
                        if let date = commit.authoredAt {
                            Text("·")
                            Text(date.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(commit.hash)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close") { inspectedCommit = nil }
            }
        }
    }

    private var blameList: some View {
        List(model.blameLines) { line in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(line.lineNumber)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
                Text(String(line.commitHash.prefix(8)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(line.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)
                Text(line.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
            }
        }
    }

    private func historySelectionHint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadHistoryMode() {
        switch historyMode {
        case .repository:
            break
        case .file:
            model.loadSelectedFileHistory()
        case .blame:
            model.loadSelectedFileBlame()
        }
    }

    private var branchesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let intelligence = currentRepositoryIntelligence, isControllableOperation(intelligence.operationMode) {
                advancedOperationCard(intelligence)
            }

            GroupBox("Branches") {
                List(model.branches) { branch in
                    HStack(spacing: 10) {
                        Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(branch.isCurrent ? .primary : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(branch.name)
                            if let upstream = branch.upstream {
                                Text(upstream)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Worktree…") { model.addWorktree(for: branch) }
                            .disabled(model.isRefreshing || model.worktrees.contains { $0.branch == branch.name })
                        if !branch.isCurrent {
                            Button("Merge…") {
                                branchToMerge = branch.name
                                showMergeConfirmation = true
                            }
                            .disabled(model.isRefreshing || hasGitOperationInProgress)

                            Button("Rebase…") {
                                branchToRebaseOnto = branch.name
                                showRebaseConfirmation = true
                            }
                            .disabled(model.isRefreshing || hasGitOperationInProgress)

                            Button("Switch") {
                                branchToSwitch = branch.name
                                showBranchConfirmation = true
                            }
                            .disabled(model.isRefreshing || hasGitOperationInProgress)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 150)
            }

            GroupBox("Worktrees") {
                VStack(spacing: 8) {
                    List(model.worktrees) { worktree in
                        HStack(spacing: 10) {
                            Image(systemName: worktree.isDetached ? "point.3.connected.trianglepath.dotted" : "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(worktree.branch ?? (worktree.isDetached ? "Detached" : "Worktree"))
                                Text(worktree.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if worktree.isLocked {
                                Label("Locked", systemImage: "lock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Open") { model.openWorktree(worktree) }
                                .disabled(model.isRefreshing)
                            if !isCurrentWorktree(worktree) {
                                Button("Remove…") { worktreeToRemove = worktree }
                                    .disabled(model.isRefreshing || worktree.isLocked)
                            }
                        }
                    }
                    .frame(minHeight: 120)

                    HStack(spacing: 8) {
                        TextField("New branch", text: $model.newWorktreeBranch)
                            .textFieldStyle(.roundedBorder)
                        TextField("Start point", text: $model.worktreeStartPoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Button("New Worktree…") { model.createWorktree() }
                            .disabled(model.newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRefreshing)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func advancedOperationCard(_ intelligence: GitRepositoryIntelligence) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        operationTitle(intelligence.operationMode),
                        systemImage: intelligence.conflictCount > 0 ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.headline)

                    if intelligence.conflictCount > 0 {
                        Text("Resolve \(intelligence.conflictCount) conflict\(intelligence.conflictCount == 1 ? "" : "s") in the Conflicts workspace before continuing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Conflicts are resolved. Continue or abort the operation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                switch intelligence.operationMode {
                case .merging:
                    Button("Continue") { model.continueMerge() }
                        .disabled(model.isRefreshing || intelligence.conflictCount > 0)
                    Button("Abort", role: .destructive) { model.abortMerge() }
                        .disabled(model.isRefreshing)
                case .rebasing:
                    Button("Continue") { model.continueRebase() }
                        .disabled(model.isRefreshing || intelligence.conflictCount > 0)
                    Button("Skip Commit") { model.skipRebaseCommit() }
                        .disabled(model.isRefreshing)
                    Button("Abort", role: .destructive) { model.abortRebase() }
                        .disabled(model.isRefreshing)
                case .cherryPicking:
                    Button("Continue") { model.continueCherryPick() }
                        .disabled(model.isRefreshing || intelligence.conflictCount > 0)
                    Button("Abort", role: .destructive) { model.abortCherryPick() }
                        .disabled(model.isRefreshing)
                case .reverting:
                    Button("Continue") { model.continueRevert() }
                        .disabled(model.isRefreshing || intelligence.conflictCount > 0)
                    Button("Abort", role: .destructive) { model.abortRevert() }
                        .disabled(model.isRefreshing)
                case .normal, .bisecting:
                    EmptyView()
                }
            }
        }
    }

    private func operationTitle(_ mode: GitRepositoryOperationMode) -> String {
        switch mode {
        case .merging: return "Merge in progress"
        case .rebasing: return "Rebase in progress"
        case .cherryPicking: return "Cherry-pick in progress"
        case .reverting: return "Revert in progress"
        case .bisecting: return "Bisect in progress"
        case .normal: return "No Git operation in progress"
        }
    }

    private var conflictView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Three-way Conflict Workspace")
                        .font(.headline)
                    Text("Compare Git's index stages, edit the result, then stage the resolved file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.conflictedPaths.isEmpty {
                    Text("\(model.conflictedPaths.count) unresolved")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if model.conflictedPaths.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No unresolved conflicts")
                        .font(.headline)
                    if let intelligence = currentRepositoryIntelligence,
                       isControllableOperation(intelligence.operationMode) {
                        Text("The repository operation is still in progress. Continue or abort it below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        advancedOperationCard(intelligence)
                            .frame(maxWidth: 680)
                    } else {
                        Text("When Git reports a text conflict, BASE / OURS / THEIRS and an editable RESULT appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conflicted Files")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        List(model.conflictedPaths, id: \.self) { path in
                            Button {
                                model.loadConflict(path: path)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: model.selectedConflictPath == path ? "arrow.right.circle.fill" : "exclamationmark.triangle")
                                    Text(path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isRefreshing || model.isLoadingConflict)
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

                    Group {
                        if model.isLoadingConflict {
                            ProgressView("Loading conflict stages…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let conflict = model.conflictFile {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(conflict.path)
                                    .font(.callout.weight(.semibold))
                                    .textSelection(.enabled)

                                HSplitView {
                                    conflictSide(title: "BASE", text: conflict.base)
                                    conflictSide(title: "OURS", text: conflict.ours)
                                    conflictSide(title: "THEIRS", text: conflict.theirs)
                                }
                                .frame(minHeight: 150, idealHeight: 210)

                                GroupBox("RESULT") {
                                    TextEditor(text: $model.conflictResult)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 190)
                                }

                                HStack(spacing: 8) {
                                    Button("Use BASE") { model.useConflictBase() }
                                        .disabled(conflict.base == nil || model.isRefreshing)
                                    Button("Use OURS") { model.useConflictOurs() }
                                        .disabled(conflict.ours == nil || model.isRefreshing)
                                    Button("Use THEIRS") { model.useConflictTheirs() }
                                        .disabled(conflict.theirs == nil || model.isRefreshing)
                                    Button("Reset") { model.resetConflictResult() }
                                        .disabled(model.isRefreshing)
                                    Spacer()
                                    Button("Resolve & Stage") { model.saveConflictResolution() }
                                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                                        .disabled(model.isRefreshing || model.isLoadingConflict)
                                }
                            }
                            .padding(.leading, 8)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.left.circle")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                                Text("Choose a conflicted file")
                                    .font(.headline)
                                Text("Branchlight will read Git's BASE, OURS and THEIRS index stages without invoking an external merge tool.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func conflictSide(title: String, text: String?) -> some View {
        GroupBox(title) {
            ScrollView([.vertical, .horizontal]) {
                Text(text ?? "Not present in this conflict stage.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(text == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(6)
            }
        }
        .frame(minWidth: 180)
    }

    private func isCurrentWorktree(_ worktree: GitWorktree) -> Bool {
        guard let repositoryURL = model.repositoryURL else { return false }
        return URL(fileURLWithPath: worktree.path, isDirectory: true).standardizedFileURL.path == repositoryURL.standardizedFileURL.path
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Choose a Git repository")
                .font(.headline)
            Text("Branchlight monitors repository state for Finder without running Git from Finder badge callbacks.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Repository…") { model.chooseRepository() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            if let errorMessage = model.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                Text(errorMessage)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if let lastOperation = model.lastOperation {
                Image(systemName: "checkmark.circle")
                Text(lastOperation)
            } else {
                Text("Finder reads cached status only. The host FSEvents watcher keeps that cache fresh; signed Finder runtime validation remains.")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundColor(model.errorMessage == nil ? .secondary : .red)
    }

    private func symbol(for kind: GitStatusKind) -> String {
        switch kind {
        case .clean: return "checkmark"
        case .staged: return "checkmark.circle"
        case .modified: return "pencil"
        case .added: return "plus.circle"
        case .deleted: return "minus.circle"
        case .renamed: return "arrow.right"
        case .untracked: return "questionmark.circle"
        case .ignored: return "eye.slash"
        case .conflicted: return "exclamationmark.triangle"
        }
    }
}

private enum HistoryMode: String, CaseIterable, Identifiable {
    case repository = "Repository"
    case file = "File"
    case blame = "Blame"

    var id: String { rawValue }
}
