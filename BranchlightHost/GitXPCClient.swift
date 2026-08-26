import BranchlightCore
import Foundation

private final class XPCReplyGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        finish { $0.resume(returning: value) }
    }

    func fail(_ error: any Error) {
        finish { $0.resume(throwing: error) }
    }

    private func finish(_ body: (CheckedContinuation<Value, any Error>) -> Void) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        body(pending)
    }
}

/// Client for the XPC service embedded in `Branchlight.app/Contents/XPCServices`.
///
/// Reads are short and may be retried through a read-only fallback adapter. Mutations
/// are deliberately different: an interrupted reply can happen after the XPC process
/// already changed Git state, so mutation calls are bounded but are never replayed
/// automatically by this client.
final class BundledGitXPCClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let readTimeoutSeconds: TimeInterval
    private let mutationTimeoutSeconds: TimeInterval

    init(
        readTimeoutSeconds: TimeInterval = 5,
        mutationTimeoutSeconds: TimeInterval = 120
    ) {
        let connection = NSXPCConnection(serviceName: BranchlightGitXPCContract.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BranchlightGitXPCProtocol.self)
        connection.resume()
        self.connection = connection
        self.readTimeoutSeconds = max(0.25, readTimeoutSeconds)
        self.mutationTimeoutSeconds = max(1, mutationTimeoutSeconds)
    }

    deinit {
        connection.invalidate()
    }

    func probe() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate<Int>(continuation)
            scheduleTimeout(gate, operation: "probe", seconds: readTimeoutSeconds)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? BranchlightGitXPCProtocol else {
                gate.fail(GitXPCContractError.unavailableProxy)
                return
            }

            proxy.probe { version in
                do {
                    try GitXPCCodec.validateProtocolVersion(version)
                    gate.succeed(version)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    func repositoryIdentity(at repositoryURL: URL) async throws -> GitRepositoryIdentity {
        let request = GitXPCRepositoryIdentityRequest(
            repositoryPath: repositoryURL.standardizedFileURL.path
        )
        let requestData = try GitXPCCodec.encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate<GitRepositoryIdentity>(continuation)
            scheduleTimeout(gate, operation: "repositoryIdentity", seconds: readTimeoutSeconds)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? BranchlightGitXPCProtocol else {
                gate.fail(GitXPCContractError.unavailableProxy)
                return
            }

            proxy.repositoryIdentity(requestData) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw GitXPCContractError.missingReplyPayload }
                    let response = try GitXPCCodec.decode(
                        GitXPCRepositoryIdentityResponse.self,
                        from: data
                    )
                    try GitXPCCodec.validateProtocolVersion(response.protocolVersion)
                    guard response.requestID == request.requestID else {
                        throw GitXPCContractError.requestIDMismatch
                    }
                    gate.succeed(response.identity)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    func repositoryIntelligence(at repositoryURL: URL) async throws -> GitRepositoryIntelligence {
        let request = GitXPCRepositoryIntelligenceRequest(
            repositoryPath: repositoryURL.standardizedFileURL.path
        )
        let requestData = try GitXPCCodec.encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate<GitRepositoryIntelligence>(continuation)
            scheduleTimeout(gate, operation: "repositoryIntelligence", seconds: readTimeoutSeconds)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? BranchlightGitXPCProtocol else {
                gate.fail(GitXPCContractError.unavailableProxy)
                return
            }

            proxy.repositoryIntelligence(requestData) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw GitXPCContractError.missingReplyPayload }
                    let response = try GitXPCCodec.decode(
                        GitXPCRepositoryIntelligenceResponse.self,
                        from: data
                    )
                    try GitXPCCodec.validateProtocolVersion(response.protocolVersion)
                    guard response.requestID == request.requestID else {
                        throw GitXPCContractError.requestIDMismatch
                    }
                    gate.succeed(response.intelligence)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    func performMutation(
        at repositoryURL: URL,
        mutation: GitXPCMutation
    ) async throws -> GitXPCMutationResponse {
        let request = GitXPCMutationRequest(
            repositoryPath: repositoryURL.standardizedFileURL.path,
            mutation: mutation
        )
        let requestData = try GitXPCCodec.encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate<GitXPCMutationResponse>(continuation)
            scheduleTimeout(gate, operation: "performMutation", seconds: mutationTimeoutSeconds)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? BranchlightGitXPCProtocol else {
                gate.fail(GitXPCContractError.unavailableProxy)
                return
            }

            proxy.performMutation(requestData) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw GitXPCContractError.missingReplyPayload }
                    let response = try GitXPCCodec.decode(
                        GitXPCMutationResponse.self,
                        from: data
                    )
                    try GitXPCCodec.validateProtocolVersion(response.protocolVersion)
                    guard response.requestID == request.requestID else {
                        throw GitXPCContractError.requestIDMismatch
                    }
                    gate.succeed(response)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    func recoveryCandidates(
        at repositoryURL: URL,
        limit: Int = 50
    ) async throws -> [GitXPCRecoveryCandidate] {
        let request = GitXPCRecoveryCandidatesRequest(
            repositoryPath: repositoryURL.standardizedFileURL.path,
            limit: limit
        )
        let requestData = try GitXPCCodec.encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate<[GitXPCRecoveryCandidate]>(continuation)
            scheduleTimeout(gate, operation: "recoveryCandidates", seconds: readTimeoutSeconds)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? BranchlightGitXPCProtocol else {
                gate.fail(GitXPCContractError.unavailableProxy)
                return
            }

            proxy.recoveryCandidates(requestData) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw GitXPCContractError.missingReplyPayload }
                    let response = try GitXPCCodec.decode(
                        GitXPCRecoveryCandidatesResponse.self,
                        from: data
                    )
                    try GitXPCCodec.validateProtocolVersion(response.protocolVersion)
                    guard response.requestID == request.requestID else {
                        throw GitXPCContractError.requestIDMismatch
                    }
                    gate.succeed(response.candidates)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    /// Recovery changes Git state and follows the same no-replay rule as ordinary
    /// mutations. A lost reply requires state reconciliation before another attempt.
    func executeRecovery(
        at repositoryURL: URL,
        operationID: UUID
    ) async throws -> GitXPCRecoveryOutcome {
        let request = GitXPCRecoveryExecuteRequest(
            repositoryPath: repositoryURL.standardizedFileURL.path,
            operationID: operationID
        )
        let requestData = try GitXPCCodec.encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate<GitXPCRecoveryOutcome>(continuation)
            scheduleTimeout(gate, operation: "executeRecovery", seconds: mutationTimeoutSeconds)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? BranchlightGitXPCProtocol else {
                gate.fail(GitXPCContractError.unavailableProxy)
                return
            }

            proxy.executeRecovery(requestData) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw GitXPCContractError.missingReplyPayload }
                    let response = try GitXPCCodec.decode(
                        GitXPCRecoveryExecuteResponse.self,
                        from: data
                    )
                    try GitXPCCodec.validateProtocolVersion(response.protocolVersion)
                    guard response.requestID == request.requestID else {
                        throw GitXPCContractError.requestIDMismatch
                    }
                    gate.succeed(response.outcome)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    private func scheduleTimeout<Value: Sendable>(
        _ gate: XPCReplyGate<Value>,
        operation: String,
        seconds: TimeInterval
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            gate.fail(
                NSError(
                    domain: "Branchlight.XPC",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Branchlight Git XPC \(operation) timed out after \(seconds) seconds. Repository state must be reconciled before retrying any mutation."
                    ]
                )
            )
        }
    }
}

/// Read-through migration adapter used by the Host while the physical XPC boundary is
/// being adopted. Repository discovery/intelligence reads are safe to retry in-process
/// because they cannot mutate Git state. This fallback pattern must never be copied to
/// Git mutations: an XPC mutation can have changed repository state even when its reply
/// is lost.
final class XPCRepositoryResolver: @unchecked Sendable {
    private let client: BundledGitXPCClient
    private let fallback: any GitService

    init(
        fallback: any GitService,
        client: BundledGitXPCClient = BundledGitXPCClient()
    ) {
        self.fallback = fallback
        self.client = client
    }

    func repositoryRoot(for url: URL) async throws -> URL {
        do {
            let identity = try await client.repositoryIdentity(at: url)
            return URL(
                fileURLWithPath: identity.workingTreeRoot,
                isDirectory: true
            ).standardizedFileURL
        } catch {
            return try await fallback.repositoryRoot(for: url)
        }
    }

    func repositoryIdentity(at repositoryURL: URL) async throws -> GitRepositoryIdentity {
        do {
            return try await client.repositoryIdentity(at: repositoryURL)
        } catch {
            return try await fallback.repositoryIdentity(at: repositoryURL)
        }
    }

    func repositoryIntelligence(at repositoryURL: URL) async throws -> GitRepositoryIntelligence {
        do {
            return try await client.repositoryIntelligence(at: repositoryURL)
        } catch {
            return try await fallback.repositoryIntelligence(at: repositoryURL)
        }
    }
}

/// Bounded bootstrap hook for signed runtime acceptance. The application can probe the
/// physical service without moving Git mutations across the boundary prematurely.
enum GitXPCBootstrapProbe {
    static func isAvailable() async -> Bool {
        let client = BundledGitXPCClient()
        return (try? await client.probe()) == BranchlightGitXPCContract.protocolVersion
    }
}
