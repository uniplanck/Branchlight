import BranchlightCore
import Foundation

private final class XPCReplyBox: @unchecked Sendable {
    private let reply: (Data?, NSError?) -> Void

    init(_ reply: @escaping (Data?, NSError?) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data?, error: NSError?) {
        reply(data, error)
    }
}

/// Foundation invokes exported XPC methods from its own connection queues. The service
/// owns only immutable references to Branchlight's Sendable runtime primitives; mutable
/// repository coordination itself is actor-backed by one coordinator shared by normal
/// and history mutations.
private final class BranchlightGitXPCService: NSObject, BranchlightGitXPCProtocol, @unchecked Sendable {
    private let gitService: InProcessGitService
    private let historyMutationService: CoordinatedGitHistoryMutationService

    override init() {
        let engine = SystemGitEngine()
        let coordinator = GitOperationCoordinator()
        let registry = GitRepositoryRegistry()
        let base = InProcessGitService(
            engine: engine,
            coordinator: coordinator,
            registry: registry
        )
        self.gitService = base
        self.historyMutationService = CoordinatedGitHistoryMutationService(
            engine: engine,
            coordinator: coordinator,
            base: base
        )
        super.init()
    }

    func probe(withReply reply: @escaping (Int) -> Void) {
        reply(BranchlightGitXPCContract.protocolVersion)
    }

    func repositoryIdentity(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let gitService = gitService

        Task { @Sendable in
            do {
                let request = try GitXPCCodec.decode(
                    GitXPCRepositoryIdentityRequest.self,
                    from: requestData
                )
                try GitXPCCodec.validateProtocolVersion(request.protocolVersion)
                let repositoryURL = try Self.validatedRepositoryURL(request.repositoryPath)
                let identity = try await gitService.repositoryIdentity(at: repositoryURL)
                let response = GitXPCRepositoryIdentityResponse(
                    requestID: request.requestID,
                    identity: identity
                )
                replyBox.send(try GitXPCCodec.encode(response), error: nil)
            } catch {
                replyBox.send(nil, error: error as NSError)
            }
        }
    }

    func repositoryIntelligence(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let gitService = gitService

        Task { @Sendable in
            do {
                let request = try GitXPCCodec.decode(
                    GitXPCRepositoryIntelligenceRequest.self,
                    from: requestData
                )
                try GitXPCCodec.validateProtocolVersion(request.protocolVersion)
                let repositoryURL = try Self.validatedRepositoryURL(request.repositoryPath)
                let intelligence = try await gitService.repositoryIntelligence(at: repositoryURL)
                let response = GitXPCRepositoryIntelligenceResponse(
                    requestID: request.requestID,
                    intelligence: intelligence
                )
                replyBox.send(try GitXPCCodec.encode(response), error: nil)
            } catch {
                replyBox.send(nil, error: error as NSError)
            }
        }
    }

    func performMutation(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let gitService = gitService
        let historyMutationService = historyMutationService

        Task { @Sendable in
            do {
                let request = try GitXPCCodec.decode(
                    GitXPCMutationRequest.self,
                    from: requestData
                )
                try GitXPCCodec.validateProtocolVersion(request.protocolVersion)
                let repositoryURL = try Self.validatedRepositoryURL(request.repositoryPath)
                let output = try await Self.execute(
                    request.mutation,
                    repositoryURL: repositoryURL,
                    gitService: gitService,
                    historyMutationService: historyMutationService
                )
                let response = GitXPCMutationResponse(
                    requestID: request.requestID,
                    output: output
                )
                replyBox.send(try GitXPCCodec.encode(response), error: nil)
            } catch {
                replyBox.send(nil, error: error as NSError)
            }
        }
    }

    func recoveryCandidates(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let gitService = gitService

        Task { @Sendable in
            do {
                let request = try GitXPCCodec.decode(
                    GitXPCRecoveryCandidatesRequest.self,
                    from: requestData
                )
                try GitXPCCodec.validateProtocolVersion(request.protocolVersion)
                let repositoryURL = try Self.validatedRepositoryURL(request.repositoryPath)
                let identity = try await gitService.repositoryIdentity(at: repositoryURL)
                let records = await gitService.recentOperations(limit: request.limit)

                let candidates = records.compactMap { record -> GitXPCRecoveryCandidate? in
                    guard record.repository.coordinationKey == identity.coordinationKey,
                          let descriptor = record.descriptor else {
                        return nil
                    }
                    let plan = GitRecoveryPlanner.plan(for: record)
                    guard plan.availability == .validationRequired else { return nil }
                    return GitXPCRecoveryCandidate(
                        operationID: record.id,
                        label: record.label,
                        intent: descriptor.intent,
                        affectedPaths: plan.affectedPaths,
                        target: plan.target,
                        reason: plan.reason
                    )
                }

                let response = GitXPCRecoveryCandidatesResponse(
                    requestID: request.requestID,
                    candidates: candidates
                )
                replyBox.send(try GitXPCCodec.encode(response), error: nil)
            } catch {
                replyBox.send(nil, error: error as NSError)
            }
        }
    }

    func executeRecovery(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let gitService = gitService

        Task { @Sendable in
            do {
                let request = try GitXPCCodec.decode(
                    GitXPCRecoveryExecuteRequest.self,
                    from: requestData
                )
                try GitXPCCodec.validateProtocolVersion(request.protocolVersion)
                let repositoryURL = try Self.validatedRepositoryURL(request.repositoryPath)
                let identity = try await gitService.repositoryIdentity(at: repositoryURL)
                let records = await gitService.recentOperations(limit: 200)
                guard let record = records.first(where: {
                    $0.id == request.operationID &&
                    $0.repository.coordinationKey == identity.coordinationKey
                }) else {
                    throw GitEngineError.invalidInput(
                        "The requested recovery operation is no longer available in the XPC journal."
                    )
                }

                let action = try await gitService.executeRecovery(for: record)
                let outcome: GitXPCRecoveryOutcome
                switch action {
                case .restoreIndex:
                    outcome = .exactIndexRestored
                case .switchBranch:
                    outcome = .branchSwitched
                case .revertCommit:
                    outcome = .revertCreated
                case .removeWorktree:
                    outcome = .worktreeRemoved
                }

                let response = GitXPCRecoveryExecuteResponse(
                    requestID: request.requestID,
                    outcome: outcome
                )
                replyBox.send(try GitXPCCodec.encode(response), error: nil)
            } catch {
                replyBox.send(nil, error: error as NSError)
            }
        }
    }

    private static func execute(
        _ mutation: GitXPCMutation,
        repositoryURL: URL,
        gitService: InProcessGitService,
        historyMutationService: CoordinatedGitHistoryMutationService
    ) async throws -> GitXPCCommandOutput? {
        switch mutation {
        case .stage(let paths):
            try await gitService.stage(at: repositoryURL, paths: paths)
            return nil

        case .unstage(let paths):
            try await gitService.unstage(at: repositoryURL, paths: paths)
            return nil

        case .applyPatch(let patch, let reverse):
            try await gitService.applyPatch(at: repositoryURL, patch: patch, reverse: reverse)
            return nil

        case .commit(let message, let amend):
            return output(try await gitService.commit(at: repositoryURL, message: message, amend: amend))

        case .fetch:
            return output(try await gitService.fetch(at: repositoryURL))

        case .pullFastForwardOnly:
            return output(try await gitService.pullFastForwardOnly(at: repositoryURL))

        case .push:
            return output(try await gitService.push(at: repositoryURL))

        case .switchBranch(let name):
            try await gitService.switchBranch(at: repositoryURL, name: name)
            return nil

        case .merge(let branch, let confirmationProvided):
            return output(
                try await gitService.merge(
                    at: repositoryURL,
                    branch: branch,
                    confirmationProvided: confirmationProvided
                )
            )

        case .continueMerge:
            return output(try await gitService.continueMerge(at: repositoryURL))

        case .abortMerge:
            return output(try await gitService.abortMerge(at: repositoryURL))

        case .rebase(let onto, let confirmationProvided):
            return output(
                try await gitService.rebase(
                    at: repositoryURL,
                    onto: onto,
                    confirmationProvided: confirmationProvided
                )
            )

        case .continueRebase:
            return output(try await gitService.continueRebase(at: repositoryURL))

        case .abortRebase:
            return output(try await gitService.abortRebase(at: repositoryURL))

        case .skipRebase:
            return output(try await gitService.skipRebase(at: repositoryURL))

        case .createStash(let message, let includeUntracked):
            return output(
                try await gitService.createStash(
                    at: repositoryURL,
                    message: message,
                    includeUntracked: includeUntracked
                )
            )

        case .applyStash(let reference, let pop):
            return output(
                try await gitService.applyStash(
                    at: repositoryURL,
                    reference: reference,
                    pop: pop
                )
            )

        case .dropStash(let reference):
            return output(try await gitService.dropStash(at: repositoryURL, reference: reference))

        case .addWorktree(let path, let branch):
            return output(
                try await gitService.addWorktree(
                    at: repositoryURL,
                    path: try validatedDestinationURL(path),
                    branch: branch
                )
            )

        case .addWorktreeWithNewBranch(let path, let newBranch, let startPoint):
            return output(
                try await gitService.addWorktree(
                    at: repositoryURL,
                    path: try validatedDestinationURL(path),
                    newBranch: newBranch,
                    startPoint: startPoint
                )
            )

        case .removeWorktree(let path):
            return output(
                try await gitService.removeWorktree(
                    at: repositoryURL,
                    path: try validatedDestinationURL(path)
                )
            )

        case .cherryPick(let commitHash, let confirmationProvided):
            return output(
                try await historyMutationService.cherryPick(
                    at: repositoryURL,
                    commitHash: commitHash,
                    confirmationProvided: confirmationProvided
                )
            )

        case .continueCherryPick:
            return output(try await historyMutationService.continueCherryPick(at: repositoryURL))

        case .abortCherryPick:
            return output(try await historyMutationService.abortCherryPick(at: repositoryURL))

        case .revert(let commitHash, let confirmationProvided):
            return output(
                try await historyMutationService.revert(
                    at: repositoryURL,
                    commitHash: commitHash,
                    confirmationProvided: confirmationProvided
                )
            )

        case .continueRevert:
            return output(try await historyMutationService.continueRevert(at: repositoryURL))

        case .abortRevert:
            return output(try await historyMutationService.abortRevert(at: repositoryURL))
        }
    }

    private static func output(_ result: GitCommandResult) -> GitXPCCommandOutput {
        GitXPCCommandOutput(stdout: result.stdout, stderr: result.stderr)
    }

    private static func validatedRepositoryURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw GitEngineError.invalidInput(
                "XPC repository requests require an absolute local path."
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func validatedDestinationURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw GitEngineError.invalidInput(
                "XPC worktree destinations require an absolute local path."
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

private final class BranchlightGitXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = BranchlightGitXPCService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: BranchlightGitXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

private let listenerDelegate = BranchlightGitXPCListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = listenerDelegate
listener.resume()
