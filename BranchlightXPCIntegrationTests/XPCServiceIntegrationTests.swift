import BranchlightCore
import Foundation
import XCTest

final class XPCServiceIntegrationTests: XCTestCase {
    func testBundledServiceLaunchesAndServesRepositoryReads() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("Branchlight-XPC-Integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try runGit(["init", "-b", "main"], at: fixture)

        let nested = fixture
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("xpc-read\n".utf8).write(
            to: nested.appendingPathComponent("change.txt"),
            options: [.atomic]
        )

        let connection = NSXPCConnection(serviceName: BranchlightGitXPCContract.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BranchlightGitXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try makeProxy(connection: connection)
        let version = try await probe(proxy)
        XCTAssertEqual(version, BranchlightGitXPCContract.protocolVersion)

        // Resolve from a nested selection, not just the repository root. This is the
        // exact read path used by Finder open-path requests and the Host repository picker.
        let identityRequest = GitXPCRepositoryIdentityRequest(
            repositoryPath: nested.standardizedFileURL.path
        )
        let identityResponse = try await repositoryIdentity(proxy, request: identityRequest)

        XCTAssertEqual(identityResponse.protocolVersion, BranchlightGitXPCContract.protocolVersion)
        XCTAssertEqual(identityResponse.requestID, identityRequest.requestID)
        XCTAssertEqual(identityResponse.identity.workingTreeRoot, fixture.standardizedFileURL.path)
        XCTAssertEqual(
            identityResponse.identity.gitDirectory,
            fixture.appendingPathComponent(".git", isDirectory: true).standardizedFileURL.path
        )
        XCTAssertEqual(
            identityResponse.identity.commonGitDirectory,
            identityResponse.identity.gitDirectory
        )

        let intelligenceRequest = GitXPCRepositoryIntelligenceRequest(
            repositoryPath: nested.standardizedFileURL.path
        )
        let intelligenceResponse = try await repositoryIntelligence(
            proxy,
            request: intelligenceRequest
        )
        let intelligence = intelligenceResponse.intelligence

        XCTAssertEqual(intelligenceResponse.protocolVersion, BranchlightGitXPCContract.protocolVersion)
        XCTAssertEqual(intelligenceResponse.requestID, intelligenceRequest.requestID)
        XCTAssertEqual(intelligence.identity, identityResponse.identity)
        XCTAssertEqual(intelligence.branch, "main")
        XCTAssertFalse(intelligence.isDetachedHead)
        XCTAssertEqual(intelligence.operationMode, .normal)
        XCTAssertEqual(intelligence.changedCount, 1)
        XCTAssertEqual(intelligence.untrackedCount, 1)
        XCTAssertEqual(intelligence.stagedCount, 0)
        XCTAssertEqual(intelligence.conflictCount, 0)
        XCTAssertNil(intelligence.upstream)
    }

    private func makeProxy(connection: NSXPCConnection) throws -> BranchlightGitXPCProtocol {
        let errorBox = XPCRemoteErrorBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            errorBox.store(error)
        }) as? BranchlightGitXPCProtocol else {
            throw GitXPCContractError.unavailableProxy
        }
        if let error = errorBox.error { throw error }
        return proxy
    }

    private func probe(_ proxy: BranchlightGitXPCProtocol) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCContinuationGate<Int>(continuation)
            scheduleTimeout(gate, operation: "probe")
            proxy.probe { version in gate.succeed(version) }
        }
    }

    private func repositoryIdentity(
        _ proxy: BranchlightGitXPCProtocol,
        request: GitXPCRepositoryIdentityRequest
    ) async throws -> GitXPCRepositoryIdentityResponse {
        let requestData = try GitXPCCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCContinuationGate<GitXPCRepositoryIdentityResponse>(continuation)
            scheduleTimeout(gate, operation: "repositoryIdentity")
            proxy.repositoryIdentity(requestData) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw GitXPCContractError.missingReplyPayload }
                    let response = try GitXPCCodec.decode(GitXPCRepositoryIdentityResponse.self, from: data)
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

    private func repositoryIntelligence(
        _ proxy: BranchlightGitXPCProtocol,
        request: GitXPCRepositoryIntelligenceRequest
    ) async throws -> GitXPCRepositoryIntelligenceResponse {
        let requestData = try GitXPCCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCContinuationGate<GitXPCRepositoryIntelligenceResponse>(continuation)
            scheduleTimeout(gate, operation: "repositoryIntelligence")
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
                    gate.succeed(response)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    private func scheduleTimeout<Value: Sendable>(
        _ gate: XPCContinuationGate<Value>,
        operation: String
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            gate.fail(
                NSError(
                    domain: "BranchlightTests.XPC",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Bundled Git XPC \(operation) timed out after 5 seconds."]
                )
            )
        }
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        try process.run()
        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "BranchlightTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: stderr, encoding: .utf8) ?? "git failed"]
            )
        }
    }
}

private final class XPCContinuationGate<Value: Sendable>: @unchecked Sendable {
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

private final class XPCRemoteErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?

    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func store(_ error: any Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
