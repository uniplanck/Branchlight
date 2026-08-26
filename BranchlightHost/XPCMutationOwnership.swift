import BranchlightCore
import Foundation

/// Host-module compatibility name used by the existing AppModel construction path.
/// The underlying implementation is no longer an in-process mutation owner: reads use
/// BranchlightCore's service while every mutation is forwarded to the bundled XPC
/// service. Keeping the construction signature stable makes the ownership cutover
/// atomic instead of forcing a broad UI rewrite in the same change.
typealias InProcessGitService = XPCMutationGitService

extension XPCMutationGitService {
    init(
        engine: SystemGitEngine = SystemGitEngine(),
        coordinator: GitOperationCoordinator = GitOperationCoordinator(),
        registry: GitRepositoryRegistry = GitRepositoryRegistry()
    ) {
        let reads = BranchlightCore.InProcessGitService(
            engine: engine,
            coordinator: coordinator,
            registry: registry
        )
        self.init(reads: reads)
    }
}

/// Compatibility façade for the history-mutation dependency already injected by
/// AppModel. It intentionally ignores the former Host coordinator because cherry-pick
/// and revert now belong to the same service-side XPC coordinator as all other Git
/// mutations.
struct CoordinatedGitHistoryMutationService: GitHistoryMutationService, Sendable {
    private let xpc: XPCGitHistoryMutationService

    init(
        engine: SystemGitEngine,
        coordinator: GitOperationCoordinator,
        base: InProcessGitService
    ) {
        _ = engine
        _ = coordinator
        _ = base
        self.xpc = XPCGitHistoryMutationService()
    }

    func cherryPick(
        at repositoryURL: URL,
        commitHash: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await xpc.cherryPick(
            at: repositoryURL,
            commitHash: commitHash,
            confirmationProvided: confirmationProvided
        )
    }

    func continueCherryPick(at repositoryURL: URL) async throws -> GitCommandResult {
        try await xpc.continueCherryPick(at: repositoryURL)
    }

    func abortCherryPick(at repositoryURL: URL) async throws -> GitCommandResult {
        try await xpc.abortCherryPick(at: repositoryURL)
    }

    func revert(
        at repositoryURL: URL,
        commitHash: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await xpc.revert(
            at: repositoryURL,
            commitHash: commitHash,
            confirmationProvided: confirmationProvided
        )
    }

    func continueRevert(at repositoryURL: URL) async throws -> GitCommandResult {
        try await xpc.continueRevert(at: repositoryURL)
    }

    func abortRevert(at repositoryURL: URL) async throws -> GitCommandResult {
        try await xpc.abortRevert(at: repositoryURL)
    }
}
