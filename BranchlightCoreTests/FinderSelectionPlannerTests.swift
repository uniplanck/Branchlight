import BranchlightCore
import Foundation
import XCTest

final class FinderSelectionPlannerTests: XCTestCase {
    private let repositoryRoot = "/tmp/branchlight-repo"

    func testDirectorySelectionAggregatesChangedDescendants() {
        let envelope = makeEnvelope()
        let plan = FinderSelectionPlanner.plan(
            absolutePaths: ["\(repositoryRoot)/Sources"],
            envelope: envelope
        )
        XCTAssertEqual(plan?.repositoryRoot, repositoryRoot)
        XCTAssertEqual(plan?.paths, ["Sources"])
        XCTAssertEqual(plan?.statuses.map(\.path), ["Sources/A.swift", "Sources/B.swift"])
        XCTAssertEqual(plan?.canStage, true)
        XCTAssertEqual(plan?.canUnstage, true)
    }

    func testRepositoryRootSelectionUsesDotPathAndAllStatuses() {
        let envelope = makeEnvelope()
        let plan = FinderSelectionPlanner.plan(
            absolutePaths: [repositoryRoot],
            envelope: envelope
        )
        XCTAssertEqual(plan?.paths, ["."])
        XCTAssertEqual(plan?.statuses.count, 3)
        XCTAssertEqual(plan?.canStage, true)
        XCTAssertEqual(plan?.canUnstage, true)
    }

    func testSelectionAcrossRepositoriesIsRejected() {
        var envelope = makeEnvelope()
        let otherRoot = "/tmp/other-repo"
        envelope.snapshots[otherRoot] = GitStatusSnapshot(
            repositoryRoot: otherRoot,
            branch: "main",
            isDetachedHead: false,
            paths: [GitPathStatus(path: "Other.swift", indexCode: " ", workTreeCode: "M", kind: .modified)]
        )
        let plan = FinderSelectionPlanner.plan(
            absolutePaths: ["\(repositoryRoot)/README.md", "\(otherRoot)/Other.swift"],
            envelope: envelope
        )
        XCTAssertNil(plan)
    }

    private func makeEnvelope() -> StatusCacheEnvelope {
        let snapshot = GitStatusSnapshot(
            repositoryRoot: repositoryRoot,
            branch: "main",
            isDetachedHead: false,
            paths: [
                GitPathStatus(path: "README.md", indexCode: "?", workTreeCode: "?", kind: .untracked),
                GitPathStatus(path: "Sources/A.swift", indexCode: " ", workTreeCode: "M", kind: .modified),
                GitPathStatus(path: "Sources/B.swift", indexCode: "M", workTreeCode: " ", kind: .staged)
            ]
        )
        return StatusCacheEnvelope(revision: 1, monitoredRoots: [repositoryRoot], snapshots: [repositoryRoot: snapshot])
    }
}

final class GitRuntimeFoundationTests: XCTestCase {
    func testCoordinatorSerializesOperationsForSameRepository() async throws {
        let coordinator = GitOperationCoordinator()
        let identity = makeIdentity()
        let firstEntered = RuntimeSignal()
        let releaseFirst = RuntimeSignal()
        let secondEntered = RuntimeSignal()

        let first = Task {
            try await coordinator.run(repository: identity, label: "first") {
                await firstEntered.signal()
                await releaseFirst.wait()
                return "first"
            }
        }
        await firstEntered.wait()

        let second = Task {
            try await coordinator.run(repository: identity, label: "second") {
                await secondEntered.signal()
                return "second"
            }
        }

        while await coordinator.queuedOperationCount(for: identity.coordinationKey) == 0 {
            await Task.yield()
        }
        let secondWasPremature = await secondEntered.isSignaled
        XCTAssertFalse(secondWasPremature)

        await releaseFirst.signal()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, "first")
        XCTAssertEqual(secondValue, "second")

        let records = await coordinator.recentOperations(limit: 2)
        XCTAssertEqual(records.map(\.label), ["second", "first"])
        XCTAssertTrue(records.allSatisfy { $0.state == .succeeded && $0.finishedAt != nil })
    }

    func testCancelledQueuedOperationNeverEntersMutationBody() async throws {
        let coordinator = GitOperationCoordinator()
        let identity = makeIdentity()
        let firstEntered = RuntimeSignal()
        let releaseFirst = RuntimeSignal()
        let cancelledBodyEntered = RuntimeSignal()
        let cancelledDescriptor = GitOperationDescriptor(
            intent: .switchBranch,
            target: "never-run"
        )

        let first = Task {
            try await coordinator.run(repository: identity, label: "blocking") {
                await firstEntered.signal()
                await releaseFirst.wait()
                return "blocking"
            }
        }
        await firstEntered.wait()

        let cancelled = Task {
            try await coordinator.run(
                repository: identity,
                label: "cancelled",
                descriptor: cancelledDescriptor
            ) {
                await cancelledBodyEntered.signal()
                return "must-not-run"
            }
        }

        while await coordinator.queuedOperationCount(for: identity.coordinationKey) == 0 {
            await Task.yield()
        }
        cancelled.cancel()
        await releaseFirst.signal()
        _ = try await first.value

        do {
            _ = try await cancelled.value
            XCTFail("Expected queued operation cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let bodyEntered = await cancelledBodyEntered.isSignaled
        XCTAssertFalse(bodyEntered)
        let records = await coordinator.recentOperations(limit: 2)
        let cancelledRecord = records.first(where: { $0.label == "cancelled" })
        XCTAssertEqual(cancelledRecord?.state, .cancelled)
        XCTAssertEqual(cancelledRecord?.descriptor, cancelledDescriptor)
    }

    func testServiceJournalRecordsStructuredStageAndBranchTargets() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightJournalTests-\(UUID().uuidString)", isDirectory: true)
        let repository = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        try initializeRepository(at: repository)
        try runGit(["branch", "feature/journal"], at: repository)
        try "changed\n".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)

        let coordinator = GitOperationCoordinator()
        let service = InProcessGitService(coordinator: coordinator)
        try await service.stage(at: repository, paths: ["tracked.txt"])
        try await service.switchBranch(at: repository, name: "feature/journal")

        let records = await service.recentOperations(limit: 2)
        XCTAssertEqual(records.count, 2)

        let branchRecord = records[0]
        XCTAssertEqual(branchRecord.descriptor?.intent, .switchBranch)
        XCTAssertEqual(branchRecord.descriptor?.target, "feature/journal")
        XCTAssertTrue(branchRecord.descriptor?.affectedPaths.isEmpty == true)

        let stageRecord = records[1]
        XCTAssertEqual(stageRecord.descriptor?.intent, .stage)
        XCTAssertEqual(stageRecord.descriptor?.affectedPaths, ["tracked.txt"])
        XCTAssertNil(stageRecord.descriptor?.reference)
        XCTAssertNil(stageRecord.descriptor?.target)
    }

    func testLinkedWorktreesShareCoordinationKeyAndRegisterSeparately() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        let repository = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        let worktree = tempDirectory.appendingPathComponent("feature-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        try initializeRepository(at: repository)
        try runGit(["worktree", "add", "-b", "feature", worktree.path], at: repository)

        let service = InProcessGitService()
        let primaryIdentity = try await service.repositoryIdentity(at: repository)
        let worktreeIdentity = try await service.repositoryIdentity(at: worktree)

        XCTAssertNotEqual(primaryIdentity.workingTreeRoot, worktreeIdentity.workingTreeRoot)
        XCTAssertNotEqual(primaryIdentity.gitDirectory, worktreeIdentity.gitDirectory)
        XCTAssertEqual(primaryIdentity.commonGitDirectory, worktreeIdentity.commonGitDirectory)
        XCTAssertEqual(primaryIdentity.coordinationKey, worktreeIdentity.coordinationKey)

        let registered = await service.registeredRepositories()
        XCTAssertEqual(registered.count, 2)
        XCTAssertEqual(Set(registered.map(\.workingTreeRoot)), Set([repository.standardizedFileURL.path, worktree.standardizedFileURL.path]))
    }

    func testRepositoryIntelligenceDetectsMergeConflict() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightIntelligenceTests-\(UUID().uuidString)", isDirectory: true)
        let repository = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        try initializeRepository(at: repository)
        try runGit(["checkout", "-b", "side"], at: repository)
        try "side\n".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit(["commit", "-m", "side change"], at: repository)

        try runGit(["checkout", "main"], at: repository)
        try "main\n".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit(["commit", "-m", "main change"], at: repository)
        let mergeStatus = try runGitAllowingFailure(["merge", "side"], at: repository)
        XCTAssertNotEqual(mergeStatus, 0)

        let intelligence = try await InProcessGitService().repositoryIntelligence(at: repository)
        XCTAssertEqual(intelligence.branch, "main")
        XCTAssertEqual(intelligence.operationMode, .merging)
        XCTAssertEqual(intelligence.conflictCount, 1)
        XCTAssertTrue(intelligence.needsConflictResolution)
        XCTAssertGreaterThanOrEqual(intelligence.changedCount, 1)
    }

    func testRepositoryIntelligenceReportsAheadBehindAndDivergence() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightTrackingTests-\(UUID().uuidString)", isDirectory: true)
        let repository = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        let remote = tempDirectory.appendingPathComponent("remote.git", isDirectory: true)
        let peer = tempDirectory.appendingPathComponent("peer", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        try runGit(["init", "--bare", "-b", "main", remote.path], at: tempDirectory)
        try initializeRepository(at: repository)
        try runGit(["remote", "add", "origin", remote.path], at: repository)
        try runGit(["push", "-u", "origin", "main"], at: repository)

        let service = InProcessGitService()
        var intelligence = try await service.repositoryIntelligence(at: repository)
        XCTAssertEqual(intelligence.upstream, "origin/main")
        XCTAssertEqual(intelligence.tracking, GitAheadBehind(ahead: 0, behind: 0))

        try "local\n".write(to: repository.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "local.txt"], at: repository)
        try runGit(["commit", "-m", "local ahead"], at: repository)
        intelligence = try await service.repositoryIntelligence(at: repository)
        XCTAssertEqual(intelligence.tracking, GitAheadBehind(ahead: 1, behind: 0))

        try runGit(["clone", remote.path, peer.path], at: tempDirectory)
        try runGit(["config", "user.email", "branchlight-peer@example.invalid"], at: peer)
        try runGit(["config", "user.name", "Branchlight Peer"], at: peer)
        try "remote\n".write(to: peer.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "remote.txt"], at: peer)
        try runGit(["commit", "-m", "remote ahead"], at: peer)
        try runGit(["push", "origin", "main"], at: peer)
        try runGit(["fetch", "origin"], at: repository)

        intelligence = try await service.repositoryIntelligence(at: repository)
        XCTAssertEqual(intelligence.tracking, GitAheadBehind(ahead: 1, behind: 1))
        XCTAssertTrue(intelligence.hasUpstreamDivergence)
        XCTAssertEqual(intelligence.tracking?.summary, "↑1 ↓1")
    }

    private func makeIdentity() -> GitRepositoryIdentity {
        GitRepositoryIdentity(
            workingTreeRoot: "/tmp/repository",
            gitDirectory: "/tmp/repository/.git",
            commonGitDirectory: "/tmp/repository/.git"
        )
    }

    private func initializeRepository(at repository: URL) throws {
        try runGit(["init", "-b", "main"], at: repository)
        try runGit(["config", "user.email", "branchlight-runtime@example.invalid"], at: repository)
        try runGit(["config", "user.name", "Branchlight Runtime Tests"], at: repository)
        try "base\n".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit(["commit", "-m", "initial"], at: repository)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let status = try runGitAllowingFailure(arguments, at: directory)
        guard status == 0 else {
            XCTFail("git \(arguments.joined(separator: " ")) failed with status \(status)")
            throw NSError(domain: "BranchlightRuntimeTests.Git", code: Int(status))
        }
    }

    private func runGitAllowingFailure(_ arguments: [String], at directory: URL) throws -> Int32 {
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
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private actor RuntimeSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool { signaled }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
