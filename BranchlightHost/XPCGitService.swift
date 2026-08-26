import BranchlightCore
import Foundation

enum XPCMutationServiceError: LocalizedError, Sendable {
    case missingCommandOutput

    var errorDescription: String? {
        switch self {
        case .missingCommandOutput:
            return "Branchlight Git XPC mutation completed without the expected command output. Repository state was not replayed and must be reconciled before retrying."
        }
    }
}

private extension BundledGitXPCClient {
    func performVoidMutation(
        at repositoryURL: URL,
        _ mutation: GitXPCMutation
    ) async throws {
        _ = try await performMutation(at: repositoryURL, mutation: mutation)
    }

    func performCommandMutation(
        at repositoryURL: URL,
        _ mutation: GitXPCMutation
    ) async throws -> GitCommandResult {
        let response = try await performMutation(at: repositoryURL, mutation: mutation)
        guard let output = response.output else {
            throw XPCMutationServiceError.missingCommandOutput
        }
        return GitCommandResult(stdout: output.stdout, stderr: output.stderr)
    }
}

/// Host-facing Git service used during the physical runtime migration.
///
/// Read-only operations continue to use the existing in-process read implementation.
/// Every Git state-changing operation is sent to the bundled XPC service and is never
/// replayed in-process if the connection or reply fails. This keeps one authoritative
/// mutation coordinator per repository while allowing the read surface to migrate
/// independently.
struct XPCMutationGitService: GitService, Sendable {
    private let reads: any GitService
    private let client: BundledGitXPCClient

    init(
        reads: any GitService,
        client: BundledGitXPCClient = BundledGitXPCClient()
    ) {
        self.reads = reads
        self.client = client
    }

    func repositoryRoot(for url: URL) async throws -> URL {
        do {
            let identity = try await client.repositoryIdentity(at: url)
            return identity.repositoryURL.standardizedFileURL
        } catch {
            return try await reads.repositoryRoot(for: url)
        }
    }

    func repositoryIdentity(at repositoryURL: URL) async throws -> GitRepositoryIdentity {
        do {
            return try await client.repositoryIdentity(at: repositoryURL)
        } catch {
            return try await reads.repositoryIdentity(at: repositoryURL)
        }
    }

    func repositoryIntelligence(at repositoryURL: URL) async throws -> GitRepositoryIntelligence {
        do {
            return try await client.repositoryIntelligence(at: repositoryURL)
        } catch {
            return try await reads.repositoryIntelligence(at: repositoryURL)
        }
    }

    func loadRepository(
        at repositoryURL: URL,
        includeMetadata: Bool,
        historyLimit: Int
    ) async throws -> GitRepositoryLoad {
        try await reads.loadRepository(
            at: repositoryURL,
            includeMetadata: includeMetadata,
            historyLimit: historyLimit
        )
    }

    func diff(at repositoryURL: URL, paths: [String], staged: Bool) async throws -> String {
        try await reads.diff(at: repositoryURL, paths: paths, staged: staged)
    }

    func structuredDiff(
        at repositoryURL: URL,
        paths: [String],
        staged: Bool
    ) async throws -> [GitDiffFile] {
        try await reads.structuredDiff(at: repositoryURL, paths: paths, staged: staged)
    }

    func stage(at repositoryURL: URL, paths: [String]) async throws {
        try await client.performVoidMutation(at: repositoryURL, .stage(paths: paths))
    }

    func unstage(at repositoryURL: URL, paths: [String]) async throws {
        try await client.performVoidMutation(at: repositoryURL, .unstage(paths: paths))
    }

    func applyPatch(at repositoryURL: URL, patch: String, reverse: Bool) async throws {
        try await client.performVoidMutation(
            at: repositoryURL,
            .applyPatch(patch: patch, reverse: reverse)
        )
    }

    func commit(
        at repositoryURL: URL,
        message: String,
        amend: Bool
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .commit(message: message, amend: amend)
        )
    }

    func fetch(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .fetch)
    }

    func pullFastForwardOnly(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .pullFastForwardOnly)
    }

    func push(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .push)
    }

    func branches(at repositoryURL: URL) async throws -> [GitBranch] {
        try await reads.branches(at: repositoryURL)
    }

    func switchBranch(at repositoryURL: URL, name: String) async throws {
        try await client.performVoidMutation(at: repositoryURL, .switchBranch(name: name))
    }

    func merge(
        at repositoryURL: URL,
        branch: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .merge(branch: branch, confirmationProvided: confirmationProvided)
        )
    }

    func continueMerge(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .continueMerge)
    }

    func abortMerge(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .abortMerge)
    }

    func rebase(
        at repositoryURL: URL,
        onto branch: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .rebase(onto: branch, confirmationProvided: confirmationProvided)
        )
    }

    func continueRebase(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .continueRebase)
    }

    func abortRebase(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .abortRebase)
    }

    func skipRebase(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .skipRebase)
    }

    func history(at repositoryURL: URL, limit: Int) async throws -> [GitCommit] {
        try await reads.history(at: repositoryURL, limit: limit)
    }

    func fileHistory(
        at repositoryURL: URL,
        path: String,
        limit: Int
    ) async throws -> [GitCommit] {
        try await reads.fileHistory(at: repositoryURL, path: path, limit: limit)
    }

    func blame(at repositoryURL: URL, path: String) async throws -> [GitBlameLine] {
        try await reads.blame(at: repositoryURL, path: path)
    }

    func stashes(at repositoryURL: URL) async throws -> [GitStashEntry] {
        try await reads.stashes(at: repositoryURL)
    }

    func createStash(
        at repositoryURL: URL,
        message: String,
        includeUntracked: Bool
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .createStash(message: message, includeUntracked: includeUntracked)
        )
    }

    func applyStash(
        at repositoryURL: URL,
        reference: String,
        pop: Bool
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .applyStash(reference: reference, pop: pop)
        )
    }

    func dropStash(
        at repositoryURL: URL,
        reference: String
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .dropStash(reference: reference)
        )
    }

    func worktrees(at repositoryURL: URL) async throws -> [GitWorktree] {
        try await reads.worktrees(at: repositoryURL)
    }

    func addWorktree(
        at repositoryURL: URL,
        path: URL,
        branch: String
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .addWorktree(path: path.standardizedFileURL.path, branch: branch)
        )
    }

    func addWorktree(
        at repositoryURL: URL,
        path: URL,
        newBranch: String,
        startPoint: String
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .addWorktreeWithNewBranch(
                path: path.standardizedFileURL.path,
                newBranch: newBranch,
                startPoint: startPoint
            )
        )
    }

    func removeWorktree(
        at repositoryURL: URL,
        path: URL
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .removeWorktree(path: path.standardizedFileURL.path)
        )
    }
}

/// Cherry-pick and revert were historically separated from `GitService`, but they must
/// move with the same ownership cutover. Both use the exact same XPC connection and the
/// same service-side coordinator as every other mutation.
struct XPCGitHistoryMutationService: GitHistoryMutationService, Sendable {
    private let client: BundledGitXPCClient

    init(client: BundledGitXPCClient = BundledGitXPCClient()) {
        self.client = client
    }

    func cherryPick(
        at repositoryURL: URL,
        commitHash: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .cherryPick(
                commitHash: commitHash,
                confirmationProvided: confirmationProvided
            )
        )
    }

    func continueCherryPick(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .continueCherryPick)
    }

    func abortCherryPick(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .abortCherryPick)
    }

    func revert(
        at repositoryURL: URL,
        commitHash: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await client.performCommandMutation(
            at: repositoryURL,
            .revert(
                commitHash: commitHash,
                confirmationProvided: confirmationProvided
            )
        )
    }

    func continueRevert(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .continueRevert)
    }

    func abortRevert(at repositoryURL: URL) async throws -> GitCommandResult {
        try await client.performCommandMutation(at: repositoryURL, .abortRevert)
    }
}
