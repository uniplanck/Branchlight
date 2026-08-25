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

public protocol GitService: Sendable {
    func repositoryRoot(for url: URL) async throws -> URL
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

    public init(engine: SystemGitEngine = SystemGitEngine()) {
        self.engine = engine
    }

    public func repositoryRoot(for url: URL) async throws -> URL {
        try await detached { try engine.repositoryRoot(for: url) }
    }

    public func loadRepository(
        at repositoryURL: URL,
        includeMetadata: Bool,
        historyLimit: Int = 30
    ) async throws -> GitRepositoryLoad {
        try await detached {
            let snapshot = try engine.status(at: repositoryURL)
            return GitRepositoryLoad(
                snapshot: snapshot,
                branches: includeMetadata ? try engine.branches(at: repositoryURL) : nil,
                history: includeMetadata ? try engine.history(at: repositoryURL, limit: historyLimit) : nil,
                stashes: includeMetadata ? try engine.stashes(at: repositoryURL) : nil,
                worktrees: includeMetadata ? try engine.worktrees(at: repositoryURL) : nil
            )
        }
    }

    public func diff(at repositoryURL: URL, paths: [String], staged: Bool) async throws -> String {
        try await detached { try engine.diff(at: repositoryURL, paths: paths, staged: staged) }
    }

    public func structuredDiff(at repositoryURL: URL, paths: [String], staged: Bool) async throws -> [GitDiffFile] {
        try await detached { try engine.structuredDiff(at: repositoryURL, paths: paths, staged: staged) }
    }

    public func stage(at repositoryURL: URL, paths: [String]) async throws {
        try await detached { try engine.stage(at: repositoryURL, paths: paths) }
    }

    public func unstage(at repositoryURL: URL, paths: [String]) async throws {
        try await detached { try engine.unstage(at: repositoryURL, paths: paths) }
    }

    public func applyPatch(at repositoryURL: URL, patch: String, reverse: Bool = false) async throws {
        try await detached { try engine.applyPatch(at: repositoryURL, patch: patch, reverse: reverse) }
    }

    public func commit(at repositoryURL: URL, message: String, amend: Bool) async throws -> GitCommandResult {
        try await detached { try engine.commit(at: repositoryURL, message: message, amend: amend) }
    }

    public func fetch(at repositoryURL: URL) async throws -> GitCommandResult {
        try await detached { try engine.fetch(at: repositoryURL) }
    }

    public func pullFastForwardOnly(at repositoryURL: URL) async throws -> GitCommandResult {
        try await detached { try engine.pullFastForwardOnly(at: repositoryURL) }
    }

    public func push(at repositoryURL: URL) async throws -> GitCommandResult {
        try await detached { try engine.push(at: repositoryURL) }
    }

    public func branches(at repositoryURL: URL) async throws -> [GitBranch] {
        try await detached { try engine.branches(at: repositoryURL) }
    }

    public func switchBranch(at repositoryURL: URL, name: String) async throws {
        try await detached { try engine.switchBranch(at: repositoryURL, name: name) }
    }

    public func history(at repositoryURL: URL, limit: Int) async throws -> [GitCommit] {
        try await detached { try engine.history(at: repositoryURL, limit: limit) }
    }

    public func fileHistory(at repositoryURL: URL, path: String, limit: Int) async throws -> [GitCommit] {
        try await detached { try engine.fileHistory(at: repositoryURL, path: path, limit: limit) }
    }

    public func blame(at repositoryURL: URL, path: String) async throws -> [GitBlameLine] {
        try await detached { try engine.blame(at: repositoryURL, path: path) }
    }

    public func stashes(at repositoryURL: URL) async throws -> [GitStashEntry] {
        try await detached { try engine.stashes(at: repositoryURL) }
    }

    public func createStash(at repositoryURL: URL, message: String, includeUntracked: Bool) async throws -> GitCommandResult {
        try await detached { try engine.createStash(at: repositoryURL, message: message, includeUntracked: includeUntracked) }
    }

    public func applyStash(at repositoryURL: URL, reference: String, pop: Bool) async throws -> GitCommandResult {
        try await detached { try engine.applyStash(at: repositoryURL, reference: reference, pop: pop) }
    }

    public func dropStash(at repositoryURL: URL, reference: String) async throws -> GitCommandResult {
        try await detached { try engine.dropStash(at: repositoryURL, reference: reference) }
    }

    public func worktrees(at repositoryURL: URL) async throws -> [GitWorktree] {
        try await detached { try engine.worktrees(at: repositoryURL) }
    }

    public func addWorktree(at repositoryURL: URL, path: URL, branch: String) async throws -> GitCommandResult {
        try await detached { try engine.addWorktree(at: repositoryURL, path: path, branch: branch) }
    }

    public func addWorktree(at repositoryURL: URL, path: URL, newBranch: String, startPoint: String) async throws -> GitCommandResult {
        try await detached { try engine.addWorktree(at: repositoryURL, path: path, newBranch: newBranch, startPoint: startPoint) }
    }

    public func removeWorktree(at repositoryURL: URL, path: URL) async throws -> GitCommandResult {
        try await detached { try engine.removeWorktree(at: repositoryURL, path: path) }
    }

    private func detached<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }
}
