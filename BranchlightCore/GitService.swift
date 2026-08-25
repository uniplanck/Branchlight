import Foundation

public struct GitRepositoryLoad: Sendable {
    public let snapshot: GitStatusSnapshot
    public let branches: [GitBranch]?
    public let history: [GitCommit]?
    public let stashes: [GitStashEntry]?
    public let worktrees: [GitWorktree]?

    public init(
        snapshot: GitStatusSnapshot,
        branches: [GitBranch]?,
        history: [GitCommit]?,
        stashes: [GitStashEntry]? = nil,
        worktrees: [GitWorktree]? = nil
    ) {
        self.snapshot = snapshot
        self.branches = branches
        self.history = history
        self.stashes = stashes
        self.worktrees = worktrees
    }
}

public actor GitOperationCoordinator {
    private var activeRepositoryKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var activeRecords: [UUID: GitOperationRecord] = [:]
    private var completedRecords: [GitOperationRecord] = []
    private let maxCompletedRecords: Int

    public init(maxCompletedRecords: Int = 200) {
        self.maxCompletedRecords = max(1, maxCompletedRecords)
    }

    public func run<T: Sendable>(
        repository: GitRepositoryIdentity,
        label: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let key = repository.coordinationKey
        await acquire(key)

        let operationID = UUID()
        let startedAt = Date()
        activeRecords[operationID] = GitOperationRecord(
            id: operationID,
            repository: repository,
            label: label,
            state: .running,
            startedAt: startedAt,
            finishedAt: nil,
            errorDescription: nil
        )

        do {
            let value = try await operation()
            finish(
                operationID: operationID,
                state: .succeeded,
                errorDescription: nil
            )
            release(key)
            return value
        } catch {
            finish(
                operationID: operationID,
                state: .failed,
                errorDescription: error.localizedDescription
            )
            release(key)
            throw error
        }
    }

    public func activeOperations() -> [GitOperationRecord] {
        activeRecords.values.sorted { $0.startedAt < $1.startedAt }
    }

    public func recentOperations(limit: Int = 50) -> [GitOperationRecord] {
        let boundedLimit = min(max(limit, 0), maxCompletedRecords)
        guard boundedLimit > 0 else { return [] }
        return Array(completedRecords.suffix(boundedLimit).reversed())
    }

    public func queuedOperationCount(for coordinationKey: String) -> Int {
        waiters[coordinationKey]?.count ?? 0
    }

    private func acquire(_ key: String) async {
        if activeRepositoryKeys.insert(key).inserted {
            return
        }

        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        guard var queue = waiters[key], !queue.isEmpty else {
            waiters.removeValue(forKey: key)
            activeRepositoryKeys.remove(key)
            return
        }

        let next = queue.removeFirst()
        if queue.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = queue
        }
        next.resume()
    }

    private func finish(
        operationID: UUID,
        state: GitOperationState,
        errorDescription: String?
    ) {
        guard let running = activeRecords.removeValue(forKey: operationID) else { return }
        completedRecords.append(
            GitOperationRecord(
                id: running.id,
                repository: running.repository,
                label: running.label,
                state: state,
                startedAt: running.startedAt,
                finishedAt: Date(),
                errorDescription: errorDescription
            )
        )

        if completedRecords.count > maxCompletedRecords {
            completedRecords.removeFirst(completedRecords.count - maxCompletedRecords)
        }
    }
}

public actor GitRepositoryRegistry {
    private var repositoriesByWorkingTreeRoot: [String: GitRepositoryIdentity] = [:]

    public init() {}

    @discardableResult
    public func register(_ repository: GitRepositoryIdentity) -> GitRepositoryIdentity {
        repositoriesByWorkingTreeRoot[repository.workingTreeRoot] = repository
        return repository
    }

    public func remove(workingTreeRoot: String) {
        repositoriesByWorkingTreeRoot.removeValue(forKey: workingTreeRoot)
    }

    public func repositories() -> [GitRepositoryIdentity] {
        repositoriesByWorkingTreeRoot.values.sorted {
            $0.workingTreeRoot.localizedStandardCompare($1.workingTreeRoot) == .orderedAscending
        }
    }

    public func repositories(sharingCoordinationKey coordinationKey: String) -> [GitRepositoryIdentity] {
        repositoriesByWorkingTreeRoot.values
            .filter { $0.coordinationKey == coordinationKey }
            .sorted {
                $0.workingTreeRoot.localizedStandardCompare($1.workingTreeRoot) == .orderedAscending
            }
    }
}

public protocol GitService: Sendable {
    func repositoryRoot(for url: URL) async throws -> URL
    func repositoryIdentity(at repositoryURL: URL) async throws -> GitRepositoryIdentity
    func loadRepository(at repositoryURL: URL, includeMetadata: Bool, historyLimit: Int) async throws -> GitRepositoryLoad
    func diff(at repositoryURL: URL, paths: [String], staged: Bool) async throws -> String
    func structuredDiff(at repositoryURL: URL, paths: [String], staged: Bool) async throws -> [GitDiffFile]
    func stage(at repositoryURL: URL, paths: [String]) async throws
    func unstage(at repositoryURL: URL, paths: [String]) async throws
    func applyPatch(at repositoryURL: URL, patch: String, reverse: Bool) async throws
    func commit(at repositoryURL: URL, message: String, amend: Bool) async throws -> GitCommandResult
    func fetch(at repositoryURL: URL) async throws -> GitCommandResult
    func pullFastForwardOnly(at repositoryURL: URL) async throws -> GitCommandResult
    func push(at repositoryURL: URL) async throws -> GitCommandResult
    func branches(at repositoryURL: URL) async throws -> [GitBranch]
    func switchBranch(at repositoryURL: URL, name: String) async throws
    func history(at repositoryURL: URL, limit: Int) async throws -> [GitCommit]
    func fileHistory(at repositoryURL: URL, path: String, limit: Int) async throws -> [GitCommit]
    func blame(at repositoryURL: URL, path: String) async throws -> [GitBlameLine]
    func stashes(at repositoryURL: URL) async throws -> [GitStashEntry]
    func createStash(at repositoryURL: URL, message: String, includeUntracked: Bool) async throws -> GitCommandResult
    func applyStash(at repositoryURL: URL, reference: String, pop: Bool) async throws -> GitCommandResult
    func dropStash(at repositoryURL: URL, reference: String) async throws -> GitCommandResult
    func worktrees(at repositoryURL: URL) async throws -> [GitWorktree]
    func addWorktree(at repositoryURL: URL, path: URL, branch: String) async throws -> GitCommandResult
    func addWorktree(at repositoryURL: URL, path: URL, newBranch: String, startPoint: String) async throws -> GitCommandResult
    func removeWorktree(at repositoryURL: URL, path: URL) async throws -> GitCommandResult
}

public struct InProcessGitService: GitService, Sendable {
    private let engine: SystemGitEngine
    private let coordinator: GitOperationCoordinator
    private let registry: GitRepositoryRegistry

    public init(
        engine: SystemGitEngine = SystemGitEngine(),
        coordinator: GitOperationCoordinator = GitOperationCoordinator(),
        registry: GitRepositoryRegistry = GitRepositoryRegistry()
    ) {
        self.engine = engine
        self.coordinator = coordinator
        self.registry = registry
    }

    public func repositoryRoot(for url: URL) async throws -> URL {
        let engine = engine
        return try await detached { try engine.repositoryRoot(for: url) }
    }

    public func repositoryIdentity(at repositoryURL: URL) async throws -> GitRepositoryIdentity {
        let engine = engine
        let identity = try await detached {
            try Self.resolveRepositoryIdentity(engine: engine, repositoryURL: repositoryURL)
        }
        await registry.register(identity)
        return identity
    }

    public func loadRepository(
        at repositoryURL: URL,
        includeMetadata: Bool,
        historyLimit: Int = 30
    ) async throws -> GitRepositoryLoad {
        let identity = try await repositoryIdentity(at: repositoryURL)
        let engine = engine
        return try await detached {
            let snapshot = try engine.status(at: identity.repositoryURL)
            return GitRepositoryLoad(
                snapshot: snapshot,
                branches: includeMetadata ? try engine.branches(at: identity.repositoryURL) : nil,
                history: includeMetadata ? try engine.history(at: identity.repositoryURL, limit: historyLimit) : nil,
                stashes: includeMetadata ? try engine.stashes(at: identity.repositoryURL) : nil,
                worktrees: includeMetadata ? try engine.worktrees(at: identity.repositoryURL) : nil
            )
        }
    }

    public func diff(at repositoryURL: URL, paths: [String], staged: Bool) async throws -> String {
        let engine = engine
        return try await detached { try engine.diff(at: repositoryURL, paths: paths, staged: staged) }
    }

    public func structuredDiff(at repositoryURL: URL, paths: [String], staged: Bool) async throws -> [GitDiffFile] {
        let engine = engine
        return try await detached { try engine.structuredDiff(at: repositoryURL, paths: paths, staged: staged) }
    }

    public func stage(at repositoryURL: URL, paths: [String]) async throws {
        try await mutate(at: repositoryURL, label: "stage \(paths.count) path(s)") { engine, root in
            try engine.stage(at: root, paths: paths)
        }
    }

    public func unstage(at repositoryURL: URL, paths: [String]) async throws {
        try await mutate(at: repositoryURL, label: "unstage \(paths.count) path(s)") { engine, root in
            try engine.unstage(at: root, paths: paths)
        }
    }

    public func applyPatch(at repositoryURL: URL, patch: String, reverse: Bool = false) async throws {
        try await mutate(at: repositoryURL, label: reverse ? "reverse staged patch" : "apply staged patch") { engine, root in
            try engine.applyPatch(at: root, patch: patch, reverse: reverse)
        }
    }

    public func commit(at repositoryURL: URL, message: String, amend: Bool) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: amend ? "amend commit" : "commit") { engine, root in
            try engine.commit(at: root, message: message, amend: amend)
        }
    }

    public func fetch(at repositoryURL: URL) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: "fetch") { engine, root in
            try engine.fetch(at: root)
        }
    }

    public func pullFastForwardOnly(at repositoryURL: URL) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: "pull --ff-only") { engine, root in
            try engine.pullFastForwardOnly(at: root)
        }
    }

    public func push(at repositoryURL: URL) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: "push") { engine, root in
            try engine.push(at: root)
        }
    }

    public func branches(at repositoryURL: URL) async throws -> [GitBranch] {
        let engine = engine
        return try await detached { try engine.branches(at: repositoryURL) }
    }

    public func switchBranch(at repositoryURL: URL, name: String) async throws {
        try await mutate(at: repositoryURL, label: "switch branch") { engine, root in
            try engine.switchBranch(at: root, name: name)
        }
    }

    public func history(at repositoryURL: URL, limit: Int) async throws -> [GitCommit] {
        let engine = engine
        return try await detached { try engine.history(at: repositoryURL, limit: limit) }
    }

    public func fileHistory(at repositoryURL: URL, path: String, limit: Int) async throws -> [GitCommit] {
        let engine = engine
        return try await detached { try engine.fileHistory(at: repositoryURL, path: path, limit: limit) }
    }

    public func blame(at repositoryURL: URL, path: String) async throws -> [GitBlameLine] {
        let engine = engine
        return try await detached { try engine.blame(at: repositoryURL, path: path) }
    }

    public func stashes(at repositoryURL: URL) async throws -> [GitStashEntry] {
        let engine = engine
        return try await detached { try engine.stashes(at: repositoryURL) }
    }

    public func createStash(at repositoryURL: URL, message: String, includeUntracked: Bool) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: "create stash") { engine, root in
            try engine.createStash(at: root, message: message, includeUntracked: includeUntracked)
        }
    }

    public func applyStash(at repositoryURL: URL, reference: String, pop: Bool) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: pop ? "pop stash" : "apply stash") { engine, root in
            try engine.applyStash(at: root, reference: reference, pop: pop)
        }
    }

    public func dropStash(at repositoryURL: URL, reference: String) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: "drop stash") { engine, root in
            try engine.dropStash(at: root, reference: reference)
        }
    }

    public func worktrees(at repositoryURL: URL) async throws -> [GitWorktree] {
        let engine = engine
        return try await detached { try engine.worktrees(at: repositoryURL) }
    }

    public func addWorktree(at repositoryURL: URL, path: URL, branch: String) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: "add worktree") { engine, root in
            try engine.addWorktree(at: root, path: path, branch: branch)
        }
    }

    public func addWorktree(at repositoryURL: URL, path: URL, newBranch: String, startPoint: String) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: "add worktree with branch") { engine, root in
            try engine.addWorktree(at: root, path: path, newBranch: newBranch, startPoint: startPoint)
        }
    }

    public func removeWorktree(at repositoryURL: URL, path: URL) async throws -> GitCommandResult {
        try await mutate(at: repositoryURL, label: "remove worktree") { engine, root in
            try engine.removeWorktree(at: root, path: path)
        }
    }

    public func registeredRepositories() async -> [GitRepositoryIdentity] {
        await registry.repositories()
    }

    public func activeOperations() async -> [GitOperationRecord] {
        await coordinator.activeOperations()
    }

    public func recentOperations(limit: Int = 50) async -> [GitOperationRecord] {
        await coordinator.recentOperations(limit: limit)
    }

    private func mutate<T: Sendable>(
        at repositoryURL: URL,
        label: String,
        operation: @escaping @Sendable (SystemGitEngine, URL) throws -> T
    ) async throws -> T {
        let identity = try await repositoryIdentity(at: repositoryURL)
        let engine = engine
        return try await coordinator.run(repository: identity, label: label) {
            try await Task.detached(priority: .userInitiated) {
                try operation(engine, identity.repositoryURL)
            }.value
        }
    }

    private func detached<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private static func resolveRepositoryIdentity(
        engine: SystemGitEngine,
        repositoryURL: URL
    ) throws -> GitRepositoryIdentity {
        let root = try engine.repositoryRoot(for: repositoryURL).standardizedFileURL
        let dotGit = root.appendingPathComponent(".git", isDirectory: false)
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            throw GitEngineError.invalidOutput("Repository metadata is missing at \(dotGit.path).")
        }

        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = dotGit.standardizedFileURL
        } else {
            let marker = try String(contentsOf: dotGit, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard marker.hasPrefix("gitdir:") else {
                throw GitEngineError.invalidOutput("Malformed Git worktree metadata at \(dotGit.path).")
            }

            let rawPath = marker.dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else {
                throw GitEngineError.invalidOutput("Git worktree metadata did not contain a git directory.")
            }

            gitDirectory = rawPath.hasPrefix("/")
                ? URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
                : root.appendingPathComponent(rawPath, isDirectory: true).standardizedFileURL
        }

        let parent = gitDirectory.deletingLastPathComponent()
        let commonGitDirectory = parent.lastPathComponent == "worktrees"
            ? parent.deletingLastPathComponent().standardizedFileURL
            : gitDirectory

        return GitRepositoryIdentity(
            workingTreeRoot: root.path,
            gitDirectory: gitDirectory.path,
            commonGitDirectory: commonGitDirectory.path
        )
    }
}
