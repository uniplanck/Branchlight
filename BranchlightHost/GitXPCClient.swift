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
/// This is intentionally not a silent per-operation fallback wrapper. Once Git
/// mutations move behind XPC, replaying an interrupted mutation in-process would be
/// unsafe because the remote side may already have changed repository state.
final class BundledGitXPCClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 5) {
        let connection = NSXPCConnection(serviceName: BranchlightGitXPCContract.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BranchlightGitXPCProtocol.self)
        connection.resume()
        self.connection = connection
        self.timeoutSeconds = max(0.25, timeoutSeconds)
    }

    deinit {
        connection.invalidate()
    }

    func probe() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate<Int>(continuation)
            scheduleTimeout(gate, operation: "probe")
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
            scheduleTimeout(gate, operation: "repositoryIdentity")
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
            scheduleTimeout(gate, operation: "repositoryIntelligence")
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

    private func scheduleTimeout<Value: Sendable>(
        _ gate: XPCReplyGate<Value>,
        operation: String
    ) {
        let timeoutSeconds = timeoutSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
            gate.fail(
                NSError(
                    domain: "Branchlight.XPC",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Branchlight Git XPC \(operation) timed out after \(timeoutSeconds) seconds."
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
