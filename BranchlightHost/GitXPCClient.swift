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

    init() {
        let connection = NSXPCConnection(serviceName: BranchlightGitXPCContract.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BranchlightGitXPCProtocol.self)
        connection.resume()
        self.connection = connection
    }

    deinit {
        connection.invalidate()
    }

    func probe() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate<Int>(continuation)
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
}

/// Bounded bootstrap hook for signed runtime acceptance. The application can probe the
/// physical service without moving Git mutations across the boundary prematurely.
enum GitXPCBootstrapProbe {
    static func isAvailable() async -> Bool {
        let client = BundledGitXPCClient()
        return (try? await client.probe()) == BranchlightGitXPCContract.protocolVersion
    }
}
