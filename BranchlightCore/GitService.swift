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
        descriptor: GitOperationDescriptor? = nil,
        checkpointProvider: (@Sendable () async -> GitRepositoryCheckpoint?)? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let key = repository.coordinationKey
        let operationID = UUID()
        let requestedAt = Date()
        await acquire(key)

        if Task.isCancelled {
            appendCompleted(
                GitOperationRecord(
                    id: operationID,
                    repository: repository,
                    label: label,
                    descriptor: descriptor,
                    state: .cancelled,
                    startedAt: requestedAt,
                    finishedAt: Date(),
                    errorDescription: CancellationError().localizedDescription
                )
            )
            release(key)
            throw CancellationError()
        }

        let preCheckpoint = await checkpointProvider?()
        activeRecords[operationID] = GitOperationRecord(
            id: operationID,
            repository: repository,
            label: label,
            descriptor: descriptor,
            preCheckpoint: preCheckpoint,
            state: .running,
            startedAt: requestedAt,
            finishedAt: nil,
            errorDescription: nil
        )

        do {
            let value = try await operation()
            let postCheckpoint = await checkpointProvider?()
            finish(
                operationID: operationID,
                state: .succeeded,
                errorDescription: nil,
                postCheckpoint: postCheckpoint
            )
            release(key)
            return value
        } catch is CancellationError {
            let postCheckpoint = await checkpointProvider?()
            finish(
                operationID: operationID,
                state: .cancelled,
                errorDescription: CancellationError().localizedDescription,
                postCheckpoint: postCheckpoint
            )
            release(key)
            throw CancellationError()
        } catch {
            let postCheckpoint = await checkpointProvider?()
            finish(
                operationID: operationID,
                state: .failed,
                errorDescription: error.localizedDescription,
                postCheckpoint: postCheckpoint
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
        if activeRepositoryKeys.insert(key).inserted { return }
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
        errorDescription: String?,
        postCheckpoint: GitRepositoryCheckpoint?
    ) {
        guard let running = activeRecords.removeValue(forKey: operationID) else { return }
        appendCompleted(
            GitOperationRecord(
                id: running.id,
                repository: running.repository,
                label: running.label,
                descriptor: running.descriptor,
                preCheckpoint: running.preCheckpoint,
                postCheckpoint: postCheckpoint,
                state: state,
                startedAt: running.startedAt,
                finishedAt: Date(),
                errorDescription: errorDescription
            )
        )
    }

    private func appendCompleted(_ record: GitOperationRecord) {
        completedRecords.append(record)
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
            .sorted { $0.workingTreeRoot.localizedStandardCompare($1.workingTreeRoot) == .orderedAscending }
    }
}

public protocol GitService: Sendable {
    func repositoryRoot(for url: URL) async throws -> URL
    func repositoryIdentity(at repositoryURL: URL) async throws -> GitRepositoryIdentity
    func repositoryIntelligence(at repositoryURL: URL) async throws -> GitRepositoryIntelligence
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
    func merge(at repositoryURL: URL, branch: String, confirmationProvided: Bool) async throws -> GitCommandResult
    func continueMerge(at repositoryURL: URL) async throws -> GitCommandResult
    func abortMerge(at repositoryURL: URL) async throws -> GitCommandResult
    func rebase(at repositoryURL: URL, onto branch: String, confirmationProvided: Bool) async throws -> GitCommandResult
    func continueRebase(at repositoryURL: URL) async throws -> GitCommandResult
    func abortRebase(at repositoryURL: URL) async throws -> GitCommandResult
    func skipRebase(at repositoryURL: URL) async throws -> GitCommandResult
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

    public func repositoryIntelligence(at repositoryURL: URL) async throws -> GitRepositoryIntelligence {
        let identity = try await repositoryIdentity(at: repositoryURL)
        let engine = engine
        return try await detached {
            try Self.captureIntelligence(engine: engine, identity: identity)
        }
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
        try await mutate(
            at: repositoryURL,
            label: "stage \(paths.count) path(s)",
            descriptor: GitOperationDescriptor(intent: .stage, affectedPaths: paths)
        ) { engine, root in
            try engine.stage(at: root, paths: paths)
        }
    }

    public func unstage(at repositoryURL: URL, paths: [String]) async throws {
        try await mutate(
            at: repositoryURL,
            label: "unstage \(paths.count) path(s)",
            descriptor: GitOperationDescriptor(intent: .unstage, affectedPaths: paths)
        ) { engine, root in
            try engine.unstage(at: root, paths: paths)
        }
    }

    public func applyPatch(at repositoryURL: URL, patch: String, reverse: Bool = false) async throws {
        try await mutate(
            at: repositoryURL,
            label: reverse ? "reverse staged patch" : "apply staged patch",
            descriptor: GitOperationDescriptor(
                intent: reverse ? .unstage : .stage,
                target: "patch",
                parameters: ["reverse": String(reverse)]
            )
        ) { engine, root in
            try engine.applyPatch(at: root, patch: patch, reverse: reverse)
        }
    }

    public func commit(at repositoryURL: URL, message: String, amend: Bool) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: amend ? "amend commit" : "commit",
            descriptor: GitOperationDescriptor(
                intent: .commit,
                target: amend ? "amend" : nil,
                parameters: ["amend": String(amend)]
            )
        ) { engine, root in
            try engine.commit(at: root, message: message, amend: amend)
        }
    }

    public func fetch(at repositoryURL: URL) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "fetch",
            descriptor: GitOperationDescriptor(intent: .fetch)
        ) { engine, root in
            try engine.fetch(at: root)
        }
    }

    public func pullFastForwardOnly(at repositoryURL: URL) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "pull --ff-only",
            descriptor: GitOperationDescriptor(intent: .pull, parameters: ["strategy": "ff-only"])
        ) { engine, root in
            try engine.pullFastForwardOnly(at: root)
        }
    }

    public func push(at repositoryURL: URL) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "push",
            descriptor: GitOperationDescriptor(intent: .push)
        ) { engine, root in
            try engine.push(at: root)
        }
    }

    public func branches(at repositoryURL: URL) async throws -> [GitBranch] {
        let engine = engine
        return try await detached { try engine.branches(at: repositoryURL) }
    }

    public func switchBranch(at repositoryURL: URL, name: String) async throws {
        try await mutate(
            at: repositoryURL,
            label: "switch branch",
            descriptor: GitOperationDescriptor(intent: .switchBranch, target: name)
        ) { engine, root in
            try engine.switchBranch(at: root, name: name)
        }
    }

    public func merge(
        at repositoryURL: URL,
        branch: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "merge \(branch)",
            descriptor: GitOperationDescriptor(
                intent: .merge,
                reference: branch,
                parameters: ["control": "start"]
            ),
            confirmationProvided: confirmationProvided
        ) { engine, root in
            try engine.merge(at: root, branch: branch)
        }
    }

    public func continueMerge(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlAdvancedOperation(
            at: repositoryURL,
            label: "continue merge",
            descriptor: GitOperationDescriptor(intent: .merge, parameters: ["control": "continue"]),
            expectedMode: .merging,
            requiresResolvedConflicts: true
        ) { engine, root in
            try engine.continueMerge(at: root)
        }
    }

    public func abortMerge(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlAdvancedOperation(
            at: repositoryURL,
            label: "abort merge",
            descriptor: GitOperationDescriptor(intent: .merge, parameters: ["control": "abort"]),
            expectedMode: .merging
        ) { engine, root in
            try engine.abortMerge(at: root)
        }
    }

    public func rebase(
        at repositoryURL: URL,
        onto branch: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "rebase onto \(branch)",
            descriptor: GitOperationDescriptor(
                intent: .rebase,
                reference: branch,
                parameters: ["control": "start"]
            ),
            confirmationProvided: confirmationProvided
        ) { engine, root in
            try engine.rebase(at: root, onto: branch)
        }
    }

    public func continueRebase(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlAdvancedOperation(
            at: repositoryURL,
            label: "continue rebase",
            descriptor: GitOperationDescriptor(intent: .rebase, parameters: ["control": "continue"]),
            expectedMode: .rebasing,
            requiresResolvedConflicts: true
        ) { engine, root in
            try engine.continueRebase(at: root)
        }
    }

    public func abortRebase(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlAdvancedOperation(
            at: repositoryURL,
            label: "abort rebase",
            descriptor: GitOperationDescriptor(intent: .rebase, parameters: ["control": "abort"]),
            expectedMode: .rebasing
        ) { engine, root in
            try engine.abortRebase(at: root)
        }
    }

    public func skipRebase(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlAdvancedOperation(
            at: repositoryURL,
            label: "skip rebase commit",
            descriptor: GitOperationDescriptor(intent: .rebase, parameters: ["control": "skip"]),
            expectedMode: .rebasing
        ) { engine, root in
            try engine.skipRebase(at: root)
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
        try await mutate(
            at: repositoryURL,
            label: "create stash",
            descriptor: GitOperationDescriptor(
                intent: .stashCreate,
                target: message,
                parameters: ["includeUntracked": String(includeUntracked)]
            )
        ) { engine, root in
            try engine.createStash(at: root, message: message, includeUntracked: includeUntracked)
        }
    }

    public func applyStash(at repositoryURL: URL, reference: String, pop: Bool) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: pop ? "pop stash" : "apply stash",
            descriptor: GitOperationDescriptor(
                intent: .stashApply,
                reference: reference,
                parameters: ["mode": pop ? "pop" : "apply"]
            )
        ) { engine, root in
            try engine.applyStash(at: root, reference: reference, pop: pop)
        }
    }

    public func dropStash(at repositoryURL: URL, reference: String) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "drop stash",
            descriptor: GitOperationDescriptor(intent: .stashDrop, reference: reference)
        ) { engine, root in
            try engine.dropStash(at: root, reference: reference)
        }
    }

    public func worktrees(at repositoryURL: URL) async throws -> [GitWorktree] {
        let engine = engine
        return try await detached { try engine.worktrees(at: repositoryURL) }
    }

    public func addWorktree(at repositoryURL: URL, path: URL, branch: String) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "add worktree",
            descriptor: GitOperationDescriptor(
                intent: .worktreeAdd,
                reference: branch,
                target: path.standardizedFileURL.path
            )
        ) { engine, root in
            try engine.addWorktree(at: root, path: path, branch: branch)
        }
    }

    public func addWorktree(at repositoryURL: URL, path: URL, newBranch: String, startPoint: String) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "add worktree with branch",
            descriptor: GitOperationDescriptor(
                intent: .worktreeAdd,
                reference: newBranch,
                target: path.standardizedFileURL.path,
                parameters: ["startPoint": startPoint, "createsBranch": "true"]
            )
        ) { engine, root in
            try engine.addWorktree(at: root, path: path, newBranch: newBranch, startPoint: startPoint)
        }
    }

    public func removeWorktree(at repositoryURL: URL, path: URL) async throws -> GitCommandResult {
        try await mutate(
            at: repositoryURL,
            label: "remove worktree",
            descriptor: GitOperationDescriptor(
                intent: .worktreeRemove,
                target: path.standardizedFileURL.path
            )
        ) { engine, root in
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

    public func executeRecovery(for record: GitOperationRecord) async throws -> GitRecoveryAction {
        let plan = GitRecoveryPlanner.plan(for: record)
        guard plan.availability == .validationRequired,
              let inverseIntent = plan.inverseIntent else {
            throw GitRecoveryValidationError.rejected([.unavailablePlan])
        }
        if record.descriptor?.target == "amend" || record.descriptor?.parameters["amend"] == "true" {
            throw GitEngineError.invalidInput("Automatic recovery for an amended commit is intentionally disabled.")
        }

        let identity = try await repositoryIdentity(at: record.repository.repositoryURL)
        guard identity.coordinationKey == record.repository.coordinationKey else {
            throw GitEngineError.invalidInput("The repository identity changed after the source operation; recovery was refused.")
        }

        let engine = engine
        let checkpointProvider: @Sendable () async -> GitRepositoryCheckpoint? = {
            await Task.detached(priority: .utility) {
                try? Self.captureCheckpoint(executableURL: engine.executableURL, identity: identity)
            }.value
        }
        let recoveryDescriptor = GitOperationDescriptor(
            intent: inverseIntent,
            affectedPaths: plan.affectedPaths,
            reference: record.id.uuidString,
            target: plan.target,
            parameters: ["recoveryOf": record.id.uuidString]
        )

        return try await coordinator.run(
            repository: identity,
            label: "recover \(record.label)",
            descriptor: recoveryDescriptor,
            checkpointProvider: checkpointProvider
        ) {
            try await Task.detached(priority: .userInitiated) {
                let currentCheckpoint = try Self.captureCheckpoint(
                    executableURL: engine.executableURL,
                    identity: identity
                )
                let currentStatus = try engine.status(at: identity.repositoryURL)
                let action = try GitRecoveryValidator.validatedAction(
                    plan: plan,
                    sourceRecord: record,
                    currentCheckpoint: currentCheckpoint,
                    currentStatus: currentStatus
                )

                switch action {
                case .switchBranch(let branch):
                    try engine.switchBranch(at: identity.repositoryURL, name: branch)

                case .revertCommit(let commit):
                    let arguments = ["-C", identity.workingTreeRoot, "revert", "--no-edit", commit]
                    let result = try Self.runGitAllowingFailure(
                        executableURL: engine.executableURL,
                        arguments: arguments
                    )
                    guard result.status == 0 else {
                        throw GitEngineError.commandFailed(
                            arguments: arguments,
                            status: result.status,
                            stderr: result.stderr
                        )
                    }

                case .removeWorktree(let path):
                    let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                    let registered = try engine.worktrees(at: identity.repositoryURL).first {
                        URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path == targetURL.path
                    }
                    guard let registered else {
                        throw GitEngineError.invalidInput("The recovery worktree is no longer registered.")
                    }
                    guard !registered.isLocked else {
                        throw GitEngineError.invalidInput("The recovery worktree is locked and cannot be removed safely.")
                    }
                    let targetStatus = try engine.status(at: targetURL)
                    guard targetStatus.isClean else {
                        throw GitRecoveryValidationError.rejected([.workingTreeNotClean])
                    }
                    _ = try engine.removeWorktree(at: identity.repositoryURL, path: targetURL)
                }

                return action
            }.value
        }
    }

    private func mutate<T: Sendable>(
        at repositoryURL: URL,
        label: String,
        descriptor: GitOperationDescriptor,
        confirmationProvided: Bool? = nil,
        operation: @escaping @Sendable (SystemGitEngine, URL) throws -> T
    ) async throws -> T {
        let identity = try await repositoryIdentity(at: repositoryURL)
        let engine = engine
        let checkpointProvider = Self.checkpointProvider(engine: engine, identity: identity)
        return try await coordinator.run(
            repository: identity,
            label: label,
            descriptor: descriptor,
            checkpointProvider: checkpointProvider
        ) {
            try await Task.detached(priority: .userInitiated) {
                let intelligence = try Self.captureIntelligence(engine: engine, identity: identity)
                let report = GitSafetyPreflight.evaluate(intent: descriptor.intent, intelligence: intelligence)

                if let confirmationProvided {
                    let admission = GitMutationAdmission(
                        report: report,
                        confirmationProvided: confirmationProvided
                    )
                    switch admission.state {
                    case .allowed:
                        break
                    case .confirmationRequired:
                        throw GitMutationAdmissionError.confirmationRequired(report)
                    case .blocked:
                        throw GitMutationAdmissionError.blocked(report)
                    }
                } else if !report.canProceed {
                    throw GitMutationAdmissionError.blocked(report)
                }

                return try operation(engine, identity.repositoryURL)
            }.value
        }
    }

    private func controlAdvancedOperation<T: Sendable>(
        at repositoryURL: URL,
        label: String,
        descriptor: GitOperationDescriptor,
        expectedMode: GitRepositoryOperationMode,
        requiresResolvedConflicts: Bool = false,
        operation: @escaping @Sendable (SystemGitEngine, URL) throws -> T
    ) async throws -> T {
        let identity = try await repositoryIdentity(at: repositoryURL)
        let engine = engine
        let checkpointProvider = Self.checkpointProvider(engine: engine, identity: identity)

        return try await coordinator.run(
            repository: identity,
            label: label,
            descriptor: descriptor,
            checkpointProvider: checkpointProvider
        ) {
            try await Task.detached(priority: .userInitiated) {
                let intelligence = try Self.captureIntelligence(engine: engine, identity: identity)
                guard intelligence.operationMode == expectedMode else {
                    throw GitEngineError.invalidInput(
                        "The requested control action requires an active \(expectedMode.rawValue) operation."
                    )
                }
                if requiresResolvedConflicts, intelligence.conflictCount > 0 {
                    throw GitEngineError.invalidInput(
                        "Resolve and stage all conflicts before continuing the Git operation."
                    )
                }
                return try operation(engine, identity.repositoryURL)
            }.value
        }
    }

    private func detached<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private static func checkpointProvider(
        engine: SystemGitEngine,
        identity: GitRepositoryIdentity
    ) -> @Sendable () async -> GitRepositoryCheckpoint? {
        {
            await Task.detached(priority: .utility) {
                try? Self.captureCheckpoint(executableURL: engine.executableURL, identity: identity)
            }.value
        }
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
            let rawPath = marker.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func captureIntelligence(
        engine: SystemGitEngine,
        identity: GitRepositoryIdentity
    ) throws -> GitRepositoryIntelligence {
        let snapshot = try engine.status(at: identity.repositoryURL)
        let branches = try engine.branches(at: identity.repositoryURL)
        let upstream = branches.first(where: { $0.isCurrent })?.upstream
        let operationMode = detectOperationMode(identity: identity)
        let tracking = try detectAheadBehind(
            executableURL: engine.executableURL,
            identity: identity,
            upstream: upstream
        )

        return GitRepositoryIntelligence(
            identity: identity,
            branch: snapshot.branch,
            upstream: upstream,
            tracking: tracking,
            isDetachedHead: snapshot.isDetachedHead,
            operationMode: operationMode,
            changedCount: snapshot.paths.count,
            stagedCount: snapshot.paths.count(where: { $0.isStaged }),
            untrackedCount: snapshot.paths.count(where: { $0.kind == .untracked }),
            conflictCount: snapshot.paths.count(where: { $0.kind == .conflicted }),
            capturedAt: snapshot.capturedAt
        )
    }

    private static func detectOperationMode(identity: GitRepositoryIdentity) -> GitRepositoryOperationMode {
        let fileManager = FileManager.default
        let gitDirectory = URL(fileURLWithPath: identity.gitDirectory, isDirectory: true)
        let commonDirectory = URL(fileURLWithPath: identity.commonGitDirectory, isDirectory: true)
        let roots = gitDirectory.path == commonDirectory.path ? [gitDirectory] : [gitDirectory, commonDirectory]

        func exists(_ relativePath: String) -> Bool {
            roots.contains { fileManager.fileExists(atPath: $0.appendingPathComponent(relativePath).path) }
        }

        if exists("rebase-merge") || exists("rebase-apply") { return .rebasing }
        if exists("MERGE_HEAD") { return .merging }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        if exists("BISECT_START") { return .bisecting }
        return .normal
    }

    private static func detectAheadBehind(
        executableURL: URL,
        identity: GitRepositoryIdentity,
        upstream: String?
    ) throws -> GitAheadBehind? {
        guard let upstream, !upstream.isEmpty else { return nil }

        let result = try runGitAllowingFailure(
            executableURL: executableURL,
            arguments: [
                "-C", identity.workingTreeRoot,
                "rev-list", "--left-right", "--count", "HEAD...\(upstream)"
            ]
        )
        guard result.status == 0 else { return nil }

        let fields = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard fields.count >= 2,
              let ahead = Int(fields[0]),
              let behind = Int(fields[1]) else {
            throw GitEngineError.invalidOutput("Could not parse upstream ahead/behind counts.")
        }
        return GitAheadBehind(ahead: ahead, behind: behind)
    }

    private static func captureCheckpoint(
        executableURL: URL,
        identity: GitRepositoryIdentity
    ) throws -> GitRepositoryCheckpoint {
        let root = identity.workingTreeRoot
        let branchResult = try runGitAllowingFailure(
            executableURL: executableURL,
            arguments: ["-C", root, "symbolic-ref", "--quiet", "--short", "HEAD"]
        )
        let headResult = try runGitAllowingFailure(
            executableURL: executableURL,
            arguments: ["-C", root, "rev-parse", "--verify", "HEAD"]
        )
        let indexResult = try runGitAllowingFailure(
            executableURL: executableURL,
            arguments: ["-C", root, "write-tree"]
        )

        let branch = branchResult.status == 0
            ? nonEmpty(branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        let head = headResult.status == 0
            ? nonEmpty(headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        let indexTree = indexResult.status == 0
            ? nonEmpty(indexResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil

        return GitRepositoryCheckpoint(
            headCommit: head,
            branch: branch,
            isDetachedHead: branchResult.status != 0,
            indexTree: indexTree,
            operationMode: detectOperationMode(identity: identity)
        )
    }

    private static func runGitAllowingFailure(
        executableURL: URL,
        arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitEngineError.executableMissing(executableURL.path)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
