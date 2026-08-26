import BranchlightCore
import Foundation
import XCTest

final class GitXPCContractTests: XCTestCase {
    func testRepositoryIdentityRequestRoundTripsWithStableIdentity() throws {
        let request = GitXPCRepositoryIdentityRequest(
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            repositoryPath: "/tmp/Branchlight Repo"
        )

        let encoded = try GitXPCCodec.encode(request)
        let decoded = try GitXPCCodec.decode(
            GitXPCRepositoryIdentityRequest.self,
            from: encoded
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.protocolVersion, BranchlightGitXPCContract.protocolVersion)
    }

    func testRepositoryIdentityResponsePreservesRequestID() throws {
        let requestID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let identity = GitRepositoryIdentity(
            workingTreeRoot: "/tmp/repo",
            gitDirectory: "/tmp/repo/.git",
            commonGitDirectory: "/tmp/repo/.git"
        )
        let response = GitXPCRepositoryIdentityResponse(
            requestID: requestID,
            identity: identity
        )

        let decoded = try GitXPCCodec.decode(
            GitXPCRepositoryIdentityResponse.self,
            from: GitXPCCodec.encode(response)
        )

        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.identity, identity)
    }

    func testProtocolVersionMismatchFailsClosed() {
        XCTAssertThrowsError(
            try GitXPCCodec.validateProtocolVersion(
                BranchlightGitXPCContract.protocolVersion + 1
            )
        ) { error in
            guard case GitXPCContractError.protocolVersionMismatch(let expected, let received) = error else {
                return XCTFail("Expected protocolVersionMismatch, got \(error)")
            }
            XCTAssertEqual(expected, BranchlightGitXPCContract.protocolVersion)
            XCTAssertEqual(received, BranchlightGitXPCContract.protocolVersion + 1)
        }
    }

    func testOversizedMessageIsRejectedBeforeTransport() {
        let request = GitXPCRepositoryIdentityRequest(
            repositoryPath: "/" + String(
                repeating: "a",
                count: BranchlightGitXPCContract.maximumMessageBytes + 32
            )
        )
        XCTAssertThrowsError(try GitXPCCodec.encode(request)) { error in
            guard case GitXPCContractError.messageTooLarge(let byteCount) = error else {
                return XCTFail("Expected messageTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(byteCount, BranchlightGitXPCContract.maximumMessageBytes)
        }
    }

    func testBundledGitXPCServiceLaunchesAndRespondsToProbe() async throws {
        let connection = NSXPCConnection(serviceName: BranchlightGitXPCContract.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BranchlightGitXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let version: Int = try await withCheckedThrowingContinuation { continuation in
            let gate = XPCProbeContinuationGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? BranchlightGitXPCProtocol else {
                gate.fail(GitXPCContractError.unavailableProxy)
                return
            }

            proxy.probe { received in
                gate.succeed(received)
            }
        }

        XCTAssertEqual(version, BranchlightGitXPCContract.protocolVersion)
    }
}

private final class XPCProbeContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, any Error>?

    init(_ continuation: CheckedContinuation<Int, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Int) {
        finish { $0.resume(returning: value) }
    }

    func fail(_ error: any Error) {
        finish { $0.resume(throwing: error) }
    }

    private func finish(_ body: (CheckedContinuation<Int, any Error>) -> Void) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        body(pending)
    }
}
