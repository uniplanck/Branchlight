import Foundation

/// Stable transport contract shared by the host and the bundled Git XPC service.
///
/// Keep this boundary small and versioned. Finder never connects to this service;
/// Finder remains cache-only and continues to emit App Group intents to the host.
public enum BranchlightGitXPCContract {
    public static let serviceName = "com.uniplanck.Branchlight.GitService"
    public static let protocolVersion = 3
    public static let maximumMessageBytes = 1_048_576
}

/// Foundation XPC deliberately carries only bounded `Data` payloads across the process
/// boundary. Branchlight's typed Swift models are encoded inside those payloads so the
/// exported Objective-C object graph stays tiny and auditable.
@objc public protocol BranchlightGitXPCProtocol {
    func probe(withReply reply: @escaping (Int) -> Void)
    func repositoryIdentity(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    func repositoryIntelligence(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    func performMutation(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    func recoveryCandidates(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    func executeRecovery(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}

public struct GitXPCRepositoryIdentityRequest: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let repositoryPath: String

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID = UUID(),
        repositoryPath: String
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.repositoryPath = repositoryPath
    }
}

public struct GitXPCRepositoryIdentityResponse: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let identity: GitRepositoryIdentity

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID,
        identity: GitRepositoryIdentity
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.identity = identity
    }
}

public struct GitXPCRepositoryIntelligenceRequest: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let repositoryPath: String

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID = UUID(),
        repositoryPath: String
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.repositoryPath = repositoryPath
    }
}

public struct GitXPCRepositoryIntelligenceResponse: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let intelligence: GitRepositoryIntelligence

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID,
        intelligence: GitRepositoryIntelligence
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.intelligence = intelligence
    }
}

/// Every Git state-changing operation that Branchlight currently exposes is represented
/// here before Host ownership is switched to XPC. Keeping this enum exhaustive prevents
/// a half-migrated runtime where two independent coordinators can mutate one repository.
public enum GitXPCMutation: Codable, Hashable, Sendable {
    case stage(paths: [String])
    case unstage(paths: [String])
    case applyPatch(patch: String, reverse: Bool)
    case commit(message: String, amend: Bool)
    case fetch
    case pullFastForwardOnly
    case push
    case switchBranch(name: String)
    case merge(branch: String, confirmationProvided: Bool)
    case continueMerge
    case abortMerge
    case rebase(onto: String, confirmationProvided: Bool)
    case continueRebase
    case abortRebase
    case skipRebase
    case createStash(message: String, includeUntracked: Bool)
    case applyStash(reference: String, pop: Bool)
    case dropStash(reference: String)
    case addWorktree(path: String, branch: String)
    case addWorktreeWithNewBranch(path: String, newBranch: String, startPoint: String)
    case removeWorktree(path: String)
    case cherryPick(commitHash: String, confirmationProvided: Bool)
    case continueCherryPick
    case abortCherryPick
    case revert(commitHash: String, confirmationProvided: Bool)
    case continueRevert
    case abortRevert
}

public struct GitXPCMutationRequest: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let repositoryPath: String
    public let mutation: GitXPCMutation

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID = UUID(),
        repositoryPath: String,
        mutation: GitXPCMutation
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.repositoryPath = repositoryPath
        self.mutation = mutation
    }
}

public struct GitXPCCommandOutput: Codable, Hashable, Sendable {
    public let stdout: String
    public let stderr: String

    public init(stdout: String, stderr: String) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct GitXPCMutationResponse: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let output: GitXPCCommandOutput?

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID,
        output: GitXPCCommandOutput? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.output = output
    }
}

/// A recovery candidate deliberately omits raw index/checkpoint bytes. Exact index
/// snapshots stay inside the XPC mutation owner and never cross the transport boundary.
public struct GitXPCRecoveryCandidate: Codable, Hashable, Identifiable, Sendable {
    public let operationID: UUID
    public let label: String
    public let intent: GitMutationIntent
    public let affectedPaths: [String]
    public let target: String?
    public let reason: String

    public var id: UUID { operationID }

    public init(
        operationID: UUID,
        label: String,
        intent: GitMutationIntent,
        affectedPaths: [String],
        target: String?,
        reason: String
    ) {
        self.operationID = operationID
        self.label = label
        self.intent = intent
        self.affectedPaths = affectedPaths
        self.target = target
        self.reason = reason
    }
}

public struct GitXPCRecoveryCandidatesRequest: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let repositoryPath: String
    public let limit: Int

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID = UUID(),
        repositoryPath: String,
        limit: Int = 50
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.repositoryPath = repositoryPath
        self.limit = min(max(limit, 1), 200)
    }
}

public struct GitXPCRecoveryCandidatesResponse: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let candidates: [GitXPCRecoveryCandidate]

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID,
        candidates: [GitXPCRecoveryCandidate]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.candidates = candidates
    }
}

public enum GitXPCRecoveryOutcome: String, Codable, Hashable, Sendable {
    case exactIndexRestored
    case branchSwitched
    case revertCreated
    case worktreeRemoved
}

public struct GitXPCRecoveryExecuteRequest: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let repositoryPath: String
    public let operationID: UUID

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID = UUID(),
        repositoryPath: String,
        operationID: UUID
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.repositoryPath = repositoryPath
        self.operationID = operationID
    }
}

public struct GitXPCRecoveryExecuteResponse: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let outcome: GitXPCRecoveryOutcome

    public init(
        protocolVersion: Int = BranchlightGitXPCContract.protocolVersion,
        requestID: UUID,
        outcome: GitXPCRecoveryOutcome
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.outcome = outcome
    }
}

public enum GitXPCContractError: LocalizedError, Sendable {
    case messageTooLarge(Int)
    case protocolVersionMismatch(expected: Int, received: Int)
    case requestIDMismatch
    case missingReplyPayload
    case unavailableProxy

    public var errorDescription: String? {
        switch self {
        case .messageTooLarge(let byteCount):
            return "Branchlight XPC message exceeded the allowed size (\(byteCount) bytes)."
        case .protocolVersionMismatch(let expected, let received):
            return "Branchlight XPC protocol mismatch: expected v\(expected), received v\(received)."
        case .requestIDMismatch:
            return "Branchlight XPC response did not match the request identity."
        case .missingReplyPayload:
            return "Branchlight XPC service returned no response payload."
        case .unavailableProxy:
            return "Branchlight Git XPC service is unavailable."
        }
    }
}

public enum GitXPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        try validateSize(data)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateSize(data)
        return try JSONDecoder().decode(type, from: data)
    }

    public static func validateProtocolVersion(_ received: Int) throws {
        let expected = BranchlightGitXPCContract.protocolVersion
        guard received == expected else {
            throw GitXPCContractError.protocolVersionMismatch(
                expected: expected,
                received: received
            )
        }
    }

    private static func validateSize(_ data: Data) throws {
        guard data.count <= BranchlightGitXPCContract.maximumMessageBytes else {
            throw GitXPCContractError.messageTooLarge(data.count)
        }
    }
}
