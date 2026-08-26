import Foundation

/// Stable transport contract shared by the host and the bundled Git XPC service.
///
/// Keep this boundary small and versioned. Finder never connects to this service;
/// Finder remains cache-only and continues to emit App Group intents to the host.
public enum BranchlightGitXPCContract {
    public static let serviceName = "com.uniplanck.Branchlight.GitService"
    public static let protocolVersion = 1
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
