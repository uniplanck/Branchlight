import AppKit
import BranchlightCore
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var repositoryURL: URL?
    @Published var monitoredRoots: [String] = []
    @Published var requestedTab: Int?
    @Published var finderIntegrationWarning: String?
    @Published var snapshot: GitStatusSnapshot?
    @Published var branches: [GitBranch] = []
    @Published var history: [GitCommit] = []
    @Published var fileHistory: [GitCommit] = []
    @Published var blameLines: [GitBlameLine] = []
    @Published var stashes: [GitStashEntry] = []
    @Published var worktrees: [GitWorktree] = []
    @Published var selectedPaths: Set<String> = []
    @Published var diffText = ""
    @Published var unstagedDiffFiles: [GitDiffFile] = []
    @Published var stagedDiffFiles: [GitDiffFile] = []
    @Published var selectedDiffLines: [String: Set<Int>] = [:]
    @Published var commitMessage = ""
    @Published var stashMessage = ""
    @Published var stashIncludeUntracked = true
    @Published var newWorktreeBranch = ""
    @Published var worktreeStartPoint = "HEAD"
    @Published var conflictFile: GitConflictFile?
    @Published var selectedConflictPath: String?
    @Published var conflictResult = ""
    @Published var isLoadingConflict = false
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var lastOperation: String?

    private let cache = HostStatusCache()
    private let finderRequestCache = HostFinderRequestCache()
    private let gitService: any GitService
    private let repositoryResolver: XPCRepositoryResolver
    private let historyMutationService: any GitHistoryMutationService
    private var repositoryWatcher: RepositoryWatcher?
    private var watcherRefreshPending = false
    private var watcherRefreshDrainActive = false

    init() {
        let engine = SystemGitEngine()
        let coordinator = GitOperationCoordinator()
        let registry = GitRepositoryRegistry()
        let base = InProcessGitService(engine: engine, coordinator: coordinator, registry: registry)
        self.gitService = base
        self.repositoryResolver = XPCRepositoryResolver(fallback: base)
        self.historyMutationService = CoordinatedGitHistoryMutationService(
            engine: engine,
            coordinator: coordinator,
            base: base
        )
        Task { await restoreCachedState() }
    }

    init(
        gitService: any GitService,
        historyMutationService: any GitHistoryMutationService
    ) {
        self.gitService = gitService
        self.repositoryResolver = XPCRepositoryResolver(fallback: gitService)
        self.historyMutationService = historyMutationService
        Task { await restoreCachedState() }
    }

    private func restoreCachedState() async {
        let envelope = await cache.load()
        monitoredRoots = envelope.monitoredRoots

        guard repositoryURL == nil, let root = envelope.monitoredRoots.first else { return }
        let restoredURL = URL(fileURLWithPath: root, isDirectory: true)
        repositoryURL = restoredURL
        finderIntegrationWarning = FinderIntegrationCompatibility.warning(for: restoredURL)
        snapshot = envelope.snapshots[root]
        startWatching(path: root)
        await refresh()
    }

    var selectedStatuses: [GitPathStatus] {
        guard let snapshot else { return [] }
        return snapshot.paths.filter { selectedPaths.contains($0.path) }
    }

    var canStageSelection: Bool {
        selectedStatuses.contains { !$0.isStaged || $0.workTreeCode != " " }
    }

    var canUnstageSelection: Bool {
        selectedStatuses.contains(where: { $0.isStaged })
    }

    var hasStagedChanges: Bool {
        snapshot?.paths.contains(where: { $0.isStaged }) == true
    }

    var conflictedPaths: [String] {
        snapshot?.paths
            .filter { $0.kind == .conflicted }
            .map(\.path)
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) ?? []
    }

    var selectedFilePath: String? {
        guard selectedPaths.count == 1 else { return nil }
        return selectedPaths.first
    }

    var canInspectSelectedFile: Bool {
        selectedFilePath != nil
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Git repository"
        panel.prompt = "Use Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selected = panel.url else { return }

        isRefreshing = true
        errorMessage = nil
        Task {
            do {
                let root = try await repositoryResolver.repositoryRoot(for: selected)
                openRepository(path: root.path)
            } catch {
                errorMessage = error.localizedDescription
                isRefreshing = false
            }
        }
    }

    func openRepository(path: String) {
        repositoryURL = URL(fileURLWithPath: path, isDirectory: true)
        finderIntegrationWarning = repositoryURL.flatMap { FinderIntegrationCompatibility.warning(for: $0) }
        selectedPaths.removeAll()
        diffText = ""
        unstagedDiffFiles = []
        stagedDiffFiles = []
        selectedDiffLines = [:]
        fileHistory = []
        blameLines = []
        stashes = []
        worktrees = []
        clearConflictWorkspace()
        errorMessage = nil
        startWatching(path: path)
        Task { await refresh() }
    }

    func consumeFinderRequest() {
        Task {
            guard let request = await finderRequestCache.consumeFinderRequest() else { return }
            switch request {
            case .intent(let intent):
                consumeFinderIntent(intent)
            case .openPath(let requestedPath):
                await consumeFinderOpenPath(requestedPath)
            }
        }
    }

    private func consumeFinderOpenPath(_ requestedPath: String) async {
        let requestedURL = URL(fileURLWithPath: requestedPath)

        do {
            let root = try await repositoryResolver.repositoryRoot(for: requestedURL)
            repositoryURL = root
            finderIntegrationWarning = FinderIntegrationCompatibility.warning(for: root)
            errorMessage = nil
            startWatching(path: root.path)

            await refresh()
            let relativePath: String
            if requestedURL.standardizedFileURL.path == root.standardizedFileURL.path {
                relativePath = ""
            } else {
                relativePath = String(
                    requestedURL.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
                )
            }

            if !relativePath.isEmpty,
               snapshot?.paths.contains(where: { $0.path == relativePath }) == true {
                selectedPaths = [relativePath]
                loadDiff()
            }
        } catch {
            errorMessage = error.localizedDescription
            isRefreshing = false
        }
    }

    private func consumeFinderIntent(_ intent: FinderIntent) {
        let root = URL(fileURLWithPath: intent.repositoryRoot, isDirectory: true).standardizedFileURL
        repositoryURL = root
        finderIntegrationWarning = FinderIntegrationCompatibility.warning(for: root)
        errorMessage = nil
        selectedPaths = Set(intent.paths.filter { $0 != "." })
        startWatching(path: root.path)

        Task {
            await refresh()

            switch intent.action {
            case .showChanges:
                requestedTab = 1
                loadDiff(paths: intent.paths == ["."] ? [] : intent.paths)
            case .stage:
                let paths = intent.paths
                runMutation(label: "Staged \(paths.count) Finder selection(s)") { service, repositoryURL in
                    try await service.stage(at: repositoryURL, paths: paths)
                }
            case .unstage:
                let paths = intent.paths
                runMutation(label: "Unstaged \(paths.count) Finder selection(s)") { service, repositoryURL in
                    try await service.unstage(at: repositoryURL, paths: paths)
                }
            case .openRepository:
                break
            }
        }
    }

    func refresh() async {
        await refresh(includeMetadata: true)
    }

    private func refreshStatusOnly() async {
        await refresh(includeMetadata: false)
    }

    private func refresh(includeMetadata: Bool) async {
        guard let repositoryURL else { return }
        isRefreshing = true
        errorMessage = nil

        do {
            let load = try await gitService.loadRepository(
                at: repositoryURL,
                includeMetadata: includeMetadata,
                historyLimit: 30
            )

            snapshot = load.snapshot
            if let refreshedBranches = load.branches {
                branches = refreshedBranches
            }
            if let refreshedHistory = load.history {
                history = refreshedHistory
            }
            if let refreshedStashes = load.stashes {
                stashes = refreshedStashes
            }
            if let refreshedWorktrees = load.worktrees {
                worktrees = refreshedWorktrees
            }
            selectedPaths = selectedPaths.intersection(Set(load.snapshot.paths.map(\.path)))
            if let selectedConflictPath,
               !load.snapshot.paths.contains(where: { $0.path == selectedConflictPath && $0.kind == .conflicted }) {
                clearConflictWorkspace()
            }
            isRefreshing = false
            persistSnapshotForFinder(load.snapshot)
        } catch {
            errorMessage = error.localizedDescription
            isRefreshing = false
        }
    }

    private func persistSnapshotForFinder(_ snapshot: GitStatusSnapshot) {
        Task {
            do {
                let envelope = try await cache.replaceSnapshot(snapshot)
                monitoredRoots = envelope?.monitoredRoots ?? monitoredRoots
            } catch {
                errorMessage = "Finder cache update failed: \(error.localizedDescription)"
            }
        }
    }

    func loadDiff() {
        loadDiff(paths: selectedPaths.sorted())
    }

    private func loadDiff(paths: [String]) {
        guard let repositoryURL else { return }
        isRefreshing = true
        errorMessage = nil

        Task {
            do {
                async let unstagedRequest = gitService.diff(at: repositoryURL, paths: paths, staged: false)
                async let stagedRequest = gitService.diff(at: repositoryURL, paths: paths, staged: true)
                let (unstaged, staged) = try await (unstagedRequest, stagedRequest)

                unstagedDiffFiles = try GitDiffParser.parse(unstaged)
                stagedDiffFiles = try GitDiffParser.parse(staged)
                selectedDiffLines = [:]

                var sections: [String] = []
                if !unstaged.isEmpty { sections.append("UNSTAGED\n\n\(unstaged)") }
                if !staged.isEmpty { sections.append("STAGED\n\n\(staged)") }
                diffText = sections.isEmpty
                    ? "No textual diff for the current selection."
                    : sections.joined(separator: "\n\n━━━━━━━━━━━━━━━━━━\n\n")
                isRefreshing = false
            } catch {
                errorMessage = error.localizedDescription
                isRefreshing = false
            }
        }
    }

    func stageSelected() {
        let paths = selectedPaths.sorted()
        runMutation(label: "Staged \(paths.count) path(s)") { service, repositoryURL in
            try await service.stage(at: repositoryURL, paths: paths)
        }
    }

    func unstageSelected() {
        let paths = selectedPaths.sorted()
        runMutation(label: "Unstaged \(paths.count) path(s)") { service, repositoryURL in
            try await service.unstage(at: repositoryURL, paths: paths)
        }
    }

    func commit() {
        let message = commitMessage
        runMutation(label: "Commit created") { service, repositoryURL in
            _ = try await service.commit(at: repositoryURL, message: message, amend: false)
        } onSuccess: {
            self.commitMessage = ""
        }
    }

    func fetch() {
        runMutation(label: "Fetch complete") { service, repositoryURL in
            _ = try await service.fetch(at: repositoryURL)
        }
    }

    func pull() {
        runMutation(label: "Fast-forward pull complete") { service, repositoryURL in
            _ = try await service.pullFastForwardOnly(at: repositoryURL)
        }
    }

    func push() {
        runMutation(label: "Push complete") { service, repositoryURL in
            _ = try await service.push(at: repositoryURL)
        }
    }

    func switchBranch(to name: String) {
        runMutation(label: "Switched to \(name)") { service, repositoryURL in
            try await service.switchBranch(at: repositoryURL, name: name)
        }
    }

    func mergeBranch(_ name: String) {
        runMutation(label: "Merged \(name)") { service, repositoryURL in
            _ = try await service.merge(
                at: repositoryURL,
                branch: name,
                confirmationProvided: true
            )
        }
    }

    func continueMerge() {
        runMutation(label: "Merge continued") { service, repositoryURL in
            _ = try await service.continueMerge(at: repositoryURL)
        }
    }

    func abortMerge() {
        runMutation(label: "Merge aborted") { service, repositoryURL in
            _ = try await service.abortMerge(at: repositoryURL)
        }
    }

    func rebaseCurrentBranch(onto name: String) {
        runMutation(label: "Rebased onto \(name)") { service, repositoryURL in
            _ = try await service.rebase(
                at: repositoryURL,
                onto: name,
                confirmationProvided: true
            )
        }
    }

    func continueRebase() {
        runMutation(label: "Rebase continued") { service, repositoryURL in
            _ = try await service.continueRebase(at: repositoryURL)
        }
    }

    func abortRebase() {
        runMutation(label: "Rebase aborted") { service, repositoryURL in
            _ = try await service.abortRebase(at: repositoryURL)
        }
    }

    func skipRebaseCommit() {
        runMutation(label: "Rebase commit skipped") { service, repositoryURL in
            _ = try await service.skipRebase(at: repositoryURL)
        }
    }

    func cherryPick(_ commit: GitCommit) {
        let historyService = historyMutationService
        runMutation(label: "Cherry-picked \(commit.shortHash)") { _, repositoryURL in
            _ = try await historyService.cherryPick(
                at: repositoryURL,
                commitHash: commit.hash,
                confirmationProvided: true
            )
        }
    }

    func continueCherryPick() {
        let historyService = historyMutationService
        runMutation(label: "Cherry-pick continued") { _, repositoryURL in
            _ = try await historyService.continueCherryPick(at: repositoryURL)
        }
    }

    func abortCherryPick() {
        let historyService = historyMutationService
        runMutation(label: "Cherry-pick aborted") { _, repositoryURL in
            _ = try await historyService.abortCherryPick(at: repositoryURL)
        }
    }

    func revert(_ commit: GitCommit) {
        let historyService = historyMutationService
        runMutation(label: "Reverted \(commit.shortHash)") { _, repositoryURL in
            _ = try await historyService.revert(
                at: repositoryURL,
                commitHash: commit.hash,
                confirmationProvided: true
            )
        }
    }

    func continueRevert() {
        let historyService = historyMutationService
        runMutation(label: "Revert continued") { _, repositoryURL in
            _ = try await historyService.continueRevert(at: repositoryURL)
        }
    }

    func abortRevert() {
        let historyService = historyMutationService
        runMutation(label: "Revert aborted") { _, repositoryURL in
            _ = try await historyService.abortRevert(at: repositoryURL)
        }
    }

    func loadConflict(path: String) {
        guard let repositoryURL else { return }
        isLoadingConflict = true
        errorMessage = nil
        Task {
            do {
                let loaded = try await gitService.conflictFile(at: repositoryURL, path: path)
                conflictFile = loaded
                selectedConflictPath = path
                conflictResult = loaded.result ?? loaded.ours ?? loaded.theirs ?? loaded.base ?? ""
                isLoadingConflict = false
            } catch {
                errorMessage = error.localizedDescription
                isLoadingConflict = false
            }
        }
    }

    func useConflictBase() {
        if let base = conflictFile?.base { conflictResult = base }
    }

    func useConflictOurs() {
        if let ours = conflictFile?.ours { conflictResult = ours }
    }

    func useConflictTheirs() {
        if let theirs = conflictFile?.theirs { conflictResult = theirs }
    }

    func resetConflictResult() {
        conflictResult = conflictFile?.result ?? ""
    }

    func saveConflictResolution() {
        guard let path = selectedConflictPath else { return }
        let result = conflictResult
        runMutation(label: "Resolved conflict in \(path)") { service, repositoryURL in
            _ = try await service.resolveConflict(at: repositoryURL, path: path, result: result)
        } onSuccess: {
            self.clearConflictWorkspace()
        }
    }

    private func clearConflictWorkspace() {
        conflictFile = nil
        selectedConflictPath = nil
        conflictResult = ""
        isLoadingConflict = false
    }

    func createStash() {
        let message = stashMessage
        let includeUntracked = stashIncludeUntracked
        runMutation(label: "Stash saved") { service, repositoryURL in
            _ = try await service.createStash(
                at: repositoryURL,
                message: message,
                includeUntracked: includeUntracked
            )
        } onSuccess: {
            self.stashMessage = ""
        }
    }

    func applyStash(_ stash: GitStashEntry, pop: Bool) {
        runMutation(label: pop ? "Stash popped" : "Stash applied") { service, repositoryURL in
            _ = try await service.applyStash(at: repositoryURL, reference: stash.reference, pop: pop)
        }
    }

    func dropStash(_ stash: GitStashEntry) {
        runMutation(label: "Stash dropped") { service, repositoryURL in
            _ = try await service.dropStash(at: repositoryURL, reference: stash.reference)
        }
    }

    func loadSelectedFileHistory() {
        guard let repositoryURL, let path = selectedFilePath else { return }
        isRefreshing = true
        errorMessage = nil
        Task {
            do {
                fileHistory = try await gitService.fileHistory(at: repositoryURL, path: path, limit: 100)
                isRefreshing = false
            } catch {
                errorMessage = error.localizedDescription
                isRefreshing = false
            }
        }
    }

    func loadSelectedFileBlame() {
        guard let repositoryURL, let path = selectedFilePath else { return }
        isRefreshing = true
        errorMessage = nil
        Task {
            do {
                blameLines = try await gitService.blame(at: repositoryURL, path: path)
                isRefreshing = false
            } catch {
                errorMessage = error.localizedDescription
                isRefreshing = false
            }
        }
    }

    func addWorktree(for branch: GitBranch) {
        guard let destination = chooseWorktreeDestination(suggestedName: branch.name) else { return }
        runMutation(label: "Worktree added for \(branch.name)") { service, repositoryURL in
            _ = try await service.addWorktree(at: repositoryURL, path: destination, branch: branch.name)
        }
    }

    func createWorktree() {
        let branch = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let startPoint = worktreeStartPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !startPoint.isEmpty else {
            errorMessage = "Enter a new branch name and start point."
            return
        }
        guard let destination = chooseWorktreeDestination(suggestedName: branch) else { return }

        runMutation(label: "Worktree created for \(branch)") { service, repositoryURL in
            _ = try await service.addWorktree(
                at: repositoryURL,
                path: destination,
                newBranch: branch,
                startPoint: startPoint
            )
        } onSuccess: {
            self.newWorktreeBranch = ""
            self.worktreeStartPoint = "HEAD"
        }
    }

    func removeWorktree(_ worktree: GitWorktree) {
        guard let repositoryURL else { return }
        let worktreeURL = URL(fileURLWithPath: worktree.path, isDirectory: true)
        guard worktreeURL.standardizedFileURL.path != repositoryURL.standardizedFileURL.path else {
            errorMessage = "The current repository worktree cannot be removed here."
            return
        }
        runMutation(label: "Worktree removed") { service, repositoryURL in
            _ = try await service.removeWorktree(at: repositoryURL, path: worktreeURL)
        }
    }

    func openWorktree(_ worktree: GitWorktree) {
        openRepository(path: worktree.path)
    }

    private func chooseWorktreeDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Choose Worktree Location"
        panel.prompt = "Create Worktree"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func diffLineSelectionKey(file: GitDiffFile, hunk: GitDiffHunk, staged: Bool) -> String {
        "\(staged ? "staged" : "unstaged")|\(file.id)|\(hunk.id)"
    }

    func selectedLineOrdinals(file: GitDiffFile, hunk: GitDiffHunk, staged: Bool) -> Set<Int> {
        selectedDiffLines[diffLineSelectionKey(file: file, hunk: hunk, staged: staged)] ?? []
    }

    func toggleDiffLine(file: GitDiffFile, hunk: GitDiffHunk, line: GitDiffLine, staged: Bool) {
        guard line.isChange else { return }
        let key = diffLineSelectionKey(file: file, hunk: hunk, staged: staged)
        var updated = selectedDiffLines
        var selection = updated[key] ?? []
        if selection.contains(line.ordinal) {
            selection.remove(line.ordinal)
        } else {
            selection.insert(line.ordinal)
        }
        if selection.isEmpty {
            updated.removeValue(forKey: key)
        } else {
            updated[key] = selection
        }
        selectedDiffLines = updated
    }

    func stageSelectedLines(file: GitDiffFile, hunk: GitDiffHunk) {
        stageLines(
            file: file,
            hunk: hunk,
            lineOrdinals: selectedLineOrdinals(file: file, hunk: hunk, staged: false)
        )
    }

    func unstageSelectedLines(file: GitDiffFile, hunk: GitDiffHunk) {
        unstageLines(
            file: file,
            hunk: hunk,
            lineOrdinals: selectedLineOrdinals(file: file, hunk: hunk, staged: true)
        )
    }

    func stageHunk(file: GitDiffFile, hunk: GitDiffHunk) {
        runPatchMutation(
            label: "Staged hunk in \(file.displayPath)",
            file: file,
            hunk: hunk,
            selectedChangedLineOrdinals: nil,
            reverse: false
        )
    }

    func unstageHunk(file: GitDiffFile, hunk: GitDiffHunk) {
        runPatchMutation(
            label: "Unstaged hunk in \(file.displayPath)",
            file: file,
            hunk: hunk,
            selectedChangedLineOrdinals: nil,
            reverse: true
        )
    }

    func stageLines(file: GitDiffFile, hunk: GitDiffHunk, lineOrdinals: Set<Int>) {
        runPatchMutation(
            label: "Staged \(lineOrdinals.count) line(s) in \(file.displayPath)",
            file: file,
            hunk: hunk,
            selectedChangedLineOrdinals: lineOrdinals,
            reverse: false
        )
    }

    func unstageLines(file: GitDiffFile, hunk: GitDiffHunk, lineOrdinals: Set<Int>) {
        runPatchMutation(
            label: "Unstaged \(lineOrdinals.count) line(s) in \(file.displayPath)",
            file: file,
            hunk: hunk,
            selectedChangedLineOrdinals: lineOrdinals,
            reverse: true
        )
    }

    private func runPatchMutation(
        label: String,
        file: GitDiffFile,
        hunk: GitDiffHunk,
        selectedChangedLineOrdinals: Set<Int>?,
        reverse: Bool
    ) {
        do {
            let patch: String
            if let selectedChangedLineOrdinals {
                patch = try GitPatchBuilder.patch(
                    for: file,
                    hunk: hunk,
                    selectedChangedLineOrdinals: selectedChangedLineOrdinals
                )
            } else {
                patch = GitPatchBuilder.patch(for: file, hunk: hunk)
            }

            runMutation(label: label) { service, repositoryURL in
                try await service.applyPatch(at: repositoryURL, patch: patch, reverse: reverse)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startWatching(path: String) {
        repositoryWatcher?.stop()
        watcherRefreshPending = false

        let watcher = RepositoryWatcher { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleWatcherRefresh()
            }
        }
        repositoryWatcher = watcher
        watcher.start(path: path)
    }

    private func scheduleWatcherRefresh() {
        watcherRefreshPending = true
        guard !watcherRefreshDrainActive else { return }

        watcherRefreshDrainActive = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.watcherRefreshDrainActive = false }

            while self.watcherRefreshPending {
                if self.isRefreshing {
                    try? await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
                    continue
                }

                self.watcherRefreshPending = false
                await self.refreshStatusOnly()
            }
        }
    }

    private func runMutation(
        label: String,
        operation: @escaping @Sendable (any GitService, URL) async throws -> Void,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard let repositoryURL else { return }
        isRefreshing = true
        errorMessage = nil
        lastOperation = nil

        Task {
            do {
                try await operation(gitService, repositoryURL)
                onSuccess?()
                lastOperation = label
                await refresh()
                if !diffText.isEmpty || !unstagedDiffFiles.isEmpty || !stagedDiffFiles.isEmpty {
                    loadDiff()
                }
            } catch {
                let mutationError = error.localizedDescription
                // A Git command can legitimately fail after changing repository state,
                // most notably merge/rebase conflicts and stash-pop conflicts. Always
                // reconcile the repository before presenting the failure to the user.
                await refresh()
                errorMessage = mutationError
                isRefreshing = false
            }
        }
    }
}
