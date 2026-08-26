@testable import Branchlight
import BranchlightCore
import Foundation
import XCTest

final class XPCServiceIntegrationTests: XCTestCase {
    func testBundledServiceLaunchesAndServesRepositoryReadsAndMutations() async throws {
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

        let initial = try await intelligence(proxy, repositoryPath: nested.path)
        XCTAssertEqual(initial.identity, identityResponse.identity)
        XCTAssertEqual(initial.branch, "main")
        XCTAssertFalse(initial.isDetachedHead)
        XCTAssertEqual(initial.operationMode, .normal)
        XCTAssertEqual(initial.changedCount, 1)
        XCTAssertEqual(initial.untrackedCount, 1)
        XCTAssertEqual(initial.stagedCount, 0)
        XCTAssertEqual(initial.conflictCount, 0)
        XCTAssertNil(initial.upstream)

        let relativePath = "Sources/Feature/change.txt"
        let stageResponse = try await performMutation(
            proxy,
            repositoryPath: nested.path,
            mutation: .stage(paths: [relativePath])
        )
        XCTAssertNil(stageResponse.output)

        let staged = try await intelligence(proxy, repositoryPath: nested.path)
        XCTAssertEqual(staged.changedCount, 1)
        XCTAssertEqual(staged.stagedCount, 1)
        XCTAssertEqual(staged.untrackedCount, 0)

        let unstageResponse = try await performMutation(
            proxy,
            repositoryPath: nested.path,
            mutation: .unstage(paths: [relativePath])
        )
        XCTAssertNil(unstageResponse.output)

        let unstaged = try await intelligence(proxy, repositoryPath: nested.path)
        XCTAssertEqual(unstaged.changedCount, 1)
        XCTAssertEqual(unstaged.stagedCount, 0)
        XCTAssertEqual(unstaged.untrackedCount, 1)
    }

    func testHostMutationAdapterExecutesThroughBundledXPC() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("Branchlight-XPC-Host-Adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        try runGit(["init", "-b", "main"], at: fixture)
        try runGit(["config", "user.name", "Branchlight XPC Test"], at: fixture)
        try runGit(["config", "user.email", "branchlight-xpc@example.invalid"], at: fixture)

        let tracked = fixture.appendingPathComponent("tracked.txt")
        try Data("host-adapter\n".utf8).write(to: tracked, options: [.atomic])

        let reads = BranchlightCore.InProcessGitService()
        let service = XPCMutationGitService(reads: reads)

        try await service.stage(at: fixture, paths: ["tracked.txt"])
        let staged = try await reads.loadRepository(at: fixture, includeMetadata: false, historyLimit: 1)
        XCTAssertEqual(staged.snapshot.paths.count, 1)
        XCTAssertTrue(staged.snapshot.paths[0].isStaged)

        let commitResult = try await service.commit(
            at: fixture,
            message: "test: host mutation adapter",
            amend: false
        )
        XCTAssertFalse(commitResult.stdout.isEmpty)

        let reconciled = try await reads.loadRepository(at: fixture, includeMetadata: true, historyLimit: 5)
        XCTAssertTrue(reconciled.snapshot.isClean)
        XCTAssertEqual(reconciled.history?.first?.subject, "test: host mutation adapter")
    }

    func testExactIndexRecoveryExecutesInsideBundledXPCOwner() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("Branchlight-XPC-Exact-Recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        try runGit(["init", "-b", "main"], at: fixture)
        try runGit(["config", "user.name", "Branchlight XPC Recovery Test"], at: fixture)
        try runGit(["config", "user.email", "branchlight-xpc-recovery@example.invalid"], at: fixture)
        let tracked = fixture.appendingPathComponent("tracked.txt")
        try Data("base\n".utf8).write(to: tracked, options: [.atomic])
        try runGit(["add", "tracked.txt"], at: fixture)
        try runGit(["commit", "-m", "initial"], at: fixture)

        try Data("modified\n".utf8).write(to: tracked, options: [.atomic])
        let client = BundledGitXPCClient(readTimeoutSeconds: 5, mutationTimeoutSeconds: 15)
        _ = try await client.performMutation(at: fixture, mutation: .stage(paths: ["tracked.txt"]))
        XCTAssertEqual(try gitOutput(["diff", "--cached", "--name-only"], at: fixture), "tracked.txt")

        let candidates = try await client.recoveryCandidates(at: fixture, limit: 20)
        let candidate = try XCTUnwrap(
            candidates.first(where: {
                $0.intent == .stage && $0.affectedPaths == ["tracked.txt"]
            })
        )
        let outcome = try await client.executeRecovery(
            at: fixture,
            operationID: candidate.operationID
        )
        XCTAssertEqual(outcome, .exactIndexRestored)

        XCTAssertEqual(try gitOutput(["diff", "--cached", "--name-only"], at: fixture), "")
        XCTAssertEqual(try gitOutput(["diff", "--name-only"], at: fixture), "tracked.txt")
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

    private func intelligence(
        _ proxy: BranchlightGitXPCProtocol,
        repositoryPath: String
    ) async throws -> GitRepositoryIntelligence {
        let request = GitXPCRepositoryIntelligenceRequest(repositoryPath: repositoryPath)
        let requestData = try GitXPCCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCContinuationGate<GitRepositoryIntelligence>(continuation)
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
                    gate.succeed(response.intelligence)
                } catch {
                    gate.fail(error)
                }
            }
        }
    }

    private func performMutation(
        _ proxy: BranchlightGitXPCProtocol,
        repositoryPath: String,
        mutation: GitXPCMutation
    ) async throws -> GitXPCMutationResponse {
        let request = GitXPCMutationRequest(
            repositoryPath: repositoryPath,
            mutation: mutation
        )
        let requestData = try GitXPCCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCContinuationGate<GitXPCMutationResponse>(continuation)
            scheduleTimeout(gate, operation: "performMutation")
            proxy.performMutation(requestData) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw GitXPCContractError.missingReplyPayload }
                    let response = try GitXPCCodec.decode(GitXPCMutationResponse.self, from: data)
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
        let result = try runGitResult(arguments, at: directory)
        guard result.status == 0 else {
            throw NSError(
                domain: "BranchlightTests.Git",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        let result = try runGitResult(arguments, at: directory)
        guard result.status == 0 else {
            throw NSError(
                domain: "BranchlightTests.Git",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGitResult(
        _ arguments: [String],
        at directory: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout, encoding: .utf8) ?? "",
            String(data: stderr, encoding: .utf8) ?? ""
        )
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
