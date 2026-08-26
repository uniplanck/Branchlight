import BranchlightCore
import Foundation
import XCTest

final class XPCServiceIntegrationTests: XCTestCase {
    func testBundledServiceLaunchesAndResolvesRepositoryIdentity() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("Branchlight-XPC-Integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try runGit(["init", "-b", "main"], at: fixture)

        let nested = fixture
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let connection = NSXPCConnection(serviceName: BranchlightGitXPCContract.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BranchlightGitXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let proxy = try makeProxy(connection: connection)
        let version = try await probe(proxy)
        XCTAssertEqual(version, BranchlightGitXPCContract.protocolVersion)

        // Resolve from a nested selection, not just the repository root. This is the
        // exact read path used by Finder open-path requests and the Host repository picker.
        let request = GitXPCRepositoryIdentityRequest(repositoryPath: nested.standardizedFileURL.path)
        let response = try await repositoryIdentity(proxy, request: request)

        XCTAssertEqual(response.protocolVersion, BranchlightGitXPCContract.protocolVersion)
        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.identity.workingTreeRoot, fixture.standardizedFileURL.path)
        XCTAssertEqual(response.identity.gitDirectory, fixture.appendingPathComponent(".git", isDirectory: true).standardizedFileURL.path)
        XCTAssertEqual(response.identity.commonGitDirectory, response.identity.gitDirectory)
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
