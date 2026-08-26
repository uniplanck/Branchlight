import BranchlightCore
import Foundation
import XCTest

final class PorcelainStatusParserTests: XCTestCase {
    func testParsesCoreStatusKinds() throws {
        let raw = " M modified.swift\0A  added.swift\0D  deleted.swift\0?? untracked.swift\0UU conflict.swift\0"
        let statuses = try PorcelainStatusParser.parse(Data(raw.utf8))

        XCTAssertEqual(statuses.map(\.path), [
            "modified.swift",
            "added.swift",
            "deleted.swift",
            "untracked.swift",
            "conflict.swift"
        ])
        XCTAssertEqual(statuses.map(\.kind), [
            .modified,
            .added,
            .deleted,
            .untracked,
            .conflicted
        ])
        XCTAssertFalse(statuses[0].isStaged)
        XCTAssertTrue(statuses[1].isStaged)
    }

    func testRenameConsumesSecondPathRecord() throws {
        let raw = "R  new-name.swift\0old-name.swift\0 M another.swift\0"
        let statuses = try PorcelainStatusParser.parse(Data(raw.utf8))

        XCTAssertEqual(statuses.count, 2)
        XCTAssertEqual(statuses[0].path, "new-name.swift")
        XCTAssertEqual(statuses[0].kind, .renamed)
        XCTAssertEqual(statuses[1].path, "another.swift")
    }

    func testConflictHasHighestAggregatePriority() {
        let aggregate = GitStatusClassifier.aggregate([
            GitStatusKind.staged,
            .untracked,
            .modified,
            .conflicted
        ])
        XCTAssertEqual(aggregate, .conflicted)
    }

    func testCacheAggregatesDescendantStatusForFolder() {
        let snapshot = GitStatusSnapshot(
            repositoryRoot: "/tmp/repo",
            branch: "main",
            isDetachedHead: false,
            paths: [
                GitPathStatus(path: "Sources/A.swift", indexCode: " ", workTreeCode: "M", kind: .modified),
                GitPathStatus(path: "README.md", indexCode: "?", workTreeCode: "?", kind: .untracked)
            ]
        )
        let envelope = StatusCacheEnvelope(snapshots: [snapshot.repositoryRoot: snapshot])

        XCTAssertEqual(envelope.statusKind(forAbsolutePath: "/tmp/repo/Sources"), .modified)
        XCTAssertEqual(envelope.statusKind(forAbsolutePath: "/tmp/repo"), .modified)
        XCTAssertEqual(envelope.statusKind(forAbsolutePath: "/tmp/repo/README.md"), .untracked)
    }
}

final class GitSafetyRuntimeIntegrationTests: XCTestCase {
    func testRuntimeBlocksBranchSwitchDuringConflictedMerge() async throws {
        let fixture = try makeRepositoryFixture(prefix: "BranchlightSafetyBlock")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try runGit(["checkout", "-b", "side"], at: fixture.repository)
        try "side\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: fixture.repository)
        try runGit(["commit", "-m", "side"], at: fixture.repository)

        try runGit(["checkout", "main"], at: fixture.repository)
        try "main\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: fixture.repository)
        try runGit(["commit", "-m", "main"], at: fixture.repository)
        XCTAssertNotEqual(try runGitAllowingFailure(["merge", "side"], at: fixture.repository), 0)

        let service = InProcessGitService()
        do {
            try await service.switchBranch(at: fixture.repository, name: "side")
            XCTFail("Expected the runtime safety gate to block branch switching during a conflicted merge.")
        } catch let error as GitMutationAdmissionError {
            switch error {
            case .blocked(let report):
                XCTAssertFalse(report.canProceed)
                XCTAssertTrue(report.signals.contains(.operationInProgress))
                XCTAssertTrue(report.signals.contains(.conflicts))
                XCTAssertEqual(report.intent, .switchBranch)
            case .confirmationRequired:
                XCTFail("A conflicted merge must be blocked, not merely confirmed.")
            }
        }

        let journal = await service.recentOperations(limit: 1)
        XCTAssertEqual(journal.first?.descriptor?.intent, .switchBranch)
        XCTAssertEqual(journal.first?.state, .failed)
    }

    func testCommitRecoveryCreatesValidatedRevertCommit() async throws {
        let fixture = try makeRepositoryFixture(prefix: "BranchlightCommitRecovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let service = InProcessGitService()
        try "changed by recoverable commit\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await service.stage(at: fixture.repository, paths: ["tracked.txt"])
        _ = try await service.commit(at: fixture.repository, message: "recoverable change", amend: false)

        let sourceRecords = await service.recentOperations(limit: 3)
        let sourceRecord = try XCTUnwrap(
            sourceRecords.first(where: { $0.descriptor?.intent == .commit })
        )
        let createdCommit = try XCTUnwrap(sourceRecord.postCheckpoint?.headCommit)
        let plan = GitRecoveryPlanner.plan(for: sourceRecord)
        XCTAssertEqual(plan.inverseIntent, .revert)
        XCTAssertEqual(plan.target, createdCommit)

        let action = try await service.executeRecovery(for: sourceRecord)
        XCTAssertEqual(action, .revertCommit(createdCommit))

        let restored = try String(
            contentsOf: fixture.repository.appendingPathComponent("tracked.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(restored, "base\n")

        let history = try await service.history(at: fixture.repository, limit: 2)
        XCTAssertEqual(history.count, 2)
        XCTAssertNotEqual(history[0].hash, createdCommit)
        XCTAssertTrue(history[0].subject.localizedCaseInsensitiveContains("revert"))

        let recoveryRecords = await service.recentOperations(limit: 3)
        let recoveryRecord = try XCTUnwrap(
            recoveryRecords.first(where: {
                $0.descriptor?.parameters["recoveryOf"] == sourceRecord.id.uuidString
            })
        )
        XCTAssertEqual(recoveryRecord.descriptor?.intent, .revert)
        XCTAssertEqual(recoveryRecord.state, .succeeded)
        XCTAssertEqual(recoveryRecord.preCheckpoint?.headCommit, createdCommit)
        XCTAssertNotEqual(recoveryRecord.postCheckpoint?.headCommit, createdCommit)
    }

    func testRecoveryIsRejectedAfterRepositoryMovesPastCheckpoint() async throws {
        let fixture = try makeRepositoryFixture(prefix: "BranchlightRecoveryMismatch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let service = InProcessGitService()
        try "first change\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await service.stage(at: fixture.repository, paths: ["tracked.txt"])
        _ = try await service.commit(at: fixture.repository, message: "first recoverable", amend: false)
        let sourceRecords = await service.recentOperations(limit: 3)
        let sourceRecord = try XCTUnwrap(
            sourceRecords.first(where: { $0.descriptor?.intent == .commit })
        )

        try "later\n".write(
            to: fixture.repository.appendingPathComponent("later.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await service.stage(at: fixture.repository, paths: ["later.txt"])
        _ = try await service.commit(at: fixture.repository, message: "later commit", amend: false)

        do {
            _ = try await service.executeRecovery(for: sourceRecord)
            XCTFail("Expected recovery to reject a repository that moved beyond the source checkpoint.")
        } catch let error as GitRecoveryValidationError {
            switch error {
            case .rejected(let issues):
                XCTAssertTrue(issues.contains(.headChanged))
            }
        }
    }

    private func makeRepositoryFixture(prefix: String) throws -> (root: URL, repository: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: repository)
        try runGit(["config", "user.email", "branchlight-safety@example.invalid"], at: repository)
        try runGit(["config", "user.name", "Branchlight Safety Tests"], at: repository)
        try "base\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit(["commit", "-m", "initial"], at: repository)
        return (root, repository)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let status = try runGitAllowingFailure(arguments, at: directory)
        guard status == 0 else {
            throw NSError(
                domain: "GitSafetyRuntimeIntegrationTests.Git",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
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

final class GitAdvancedEngineIntegrationTests: XCTestCase {
    private let engine = SystemGitEngine()

    func testMergeConflictCanBeResolvedAndContinued() async throws {
        let fixture = try makeFixture(prefix: "BranchlightMergeContinue")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeDivergedConflict(in: fixture.repository, sideBranch: "side")
        XCTAssertThrowsError(try engine.merge(at: fixture.repository, branch: "side"))

        var intelligence = try await InProcessGitService().repositoryIntelligence(at: fixture.repository)
        XCTAssertEqual(intelligence.operationMode, .merging)
        XCTAssertEqual(intelligence.conflictCount, 1)

        try "resolved merge\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try engine.stage(at: fixture.repository, paths: ["tracked.txt"])
        _ = try engine.continueMerge(at: fixture.repository)

        intelligence = try await InProcessGitService().repositoryIntelligence(at: fixture.repository)
        XCTAssertEqual(intelligence.operationMode, .normal)
        XCTAssertEqual(intelligence.conflictCount, 0)
        XCTAssertTrue(try engine.status(at: fixture.repository).isClean)
        XCTAssertEqual(try engine.status(at: fixture.repository).branch, "main")
    }

    func testMergeConflictCanBeAborted() async throws {
        let fixture = try makeFixture(prefix: "BranchlightMergeAbort")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeDivergedConflict(in: fixture.repository, sideBranch: "side")
        XCTAssertThrowsError(try engine.merge(at: fixture.repository, branch: "side"))
        _ = try engine.abortMerge(at: fixture.repository)

        let intelligence = try await InProcessGitService().repositoryIntelligence(at: fixture.repository)
        XCTAssertEqual(intelligence.operationMode, .normal)
        XCTAssertTrue(try engine.status(at: fixture.repository).isClean)
        let restored = try String(
            contentsOf: fixture.repository.appendingPathComponent("tracked.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(restored, "main\n")
    }

    func testRebaseConflictCanBeResolvedAndContinued() async throws {
        let fixture = try makeFixture(prefix: "BranchlightRebaseContinue")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try runGit(["checkout", "-b", "feature"], at: fixture.repository)
        try "feature\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: fixture.repository)
        try runGit(["commit", "-m", "feature change"], at: fixture.repository)

        try runGit(["checkout", "main"], at: fixture.repository)
        try "main\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: fixture.repository)
        try runGit(["commit", "-m", "main change"], at: fixture.repository)
        try runGit(["checkout", "feature"], at: fixture.repository)

        XCTAssertThrowsError(try engine.rebase(at: fixture.repository, onto: "main"))
        var intelligence = try await InProcessGitService().repositoryIntelligence(at: fixture.repository)
        XCTAssertEqual(intelligence.operationMode, .rebasing)
        XCTAssertEqual(intelligence.conflictCount, 1)

        try "resolved rebase\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try engine.stage(at: fixture.repository, paths: ["tracked.txt"])
        _ = try engine.continueRebase(at: fixture.repository)

        intelligence = try await InProcessGitService().repositoryIntelligence(at: fixture.repository)
        XCTAssertEqual(intelligence.operationMode, .normal)
        XCTAssertTrue(try engine.status(at: fixture.repository).isClean)
        XCTAssertEqual(try engine.status(at: fixture.repository).branch, "feature")
        XCTAssertEqual(try engine.history(at: fixture.repository, limit: 1).first?.subject, "feature change")
    }

    func testRebaseConflictCanBeAborted() async throws {
        let fixture = try makeFixture(prefix: "BranchlightRebaseAbort")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try runGit(["checkout", "-b", "feature"], at: fixture.repository)
        try "feature\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: fixture.repository)
        try runGit(["commit", "-m", "feature change"], at: fixture.repository)
        let featureHead = try gitOutput(["rev-parse", "HEAD"], at: fixture.repository)

        try runGit(["checkout", "main"], at: fixture.repository)
        try "main\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: fixture.repository)
        try runGit(["commit", "-m", "main change"], at: fixture.repository)
        try runGit(["checkout", "feature"], at: fixture.repository)

        XCTAssertThrowsError(try engine.rebase(at: fixture.repository, onto: "main"))
        _ = try engine.abortRebase(at: fixture.repository)

        let intelligence = try await InProcessGitService().repositoryIntelligence(at: fixture.repository)
        XCTAssertEqual(intelligence.operationMode, .normal)
        XCTAssertEqual(try gitOutput(["rev-parse", "HEAD"], at: fixture.repository), featureHead)
        XCTAssertTrue(try engine.status(at: fixture.repository).isClean)
    }

    func testMergeAndRebaseRejectOptionLikeBranchNames() throws {
        let fixture = try makeFixture(prefix: "BranchlightAdvancedInput")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try engine.merge(at: fixture.repository, branch: "--help"))
        XCTAssertThrowsError(try engine.rebase(at: fixture.repository, onto: "--onto"))
    }

    private func makeFixture(prefix: String) throws -> (root: URL, repository: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: repository)
        try runGit(["config", "user.email", "branchlight-advanced@example.invalid"], at: repository)
        try runGit(["config", "user.name", "Branchlight Advanced Tests"], at: repository)
        try "base\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit(["commit", "-m", "initial"], at: repository)
        return (root, repository)
    }

    private func makeDivergedConflict(in repository: URL, sideBranch: String) throws {
        try runGit(["checkout", "-b", sideBranch], at: repository)
        try "side\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit(["commit", "-m", "side change"], at: repository)

        try runGit(["checkout", "main"], at: repository)
        try "main\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: repository)
        try runGit(["commit", "-m", "main change"], at: repository)
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitAdvancedEngineIntegrationTests.Git", code: Int(process.terminationStatus))
        }
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitAdvancedEngineIntegrationTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
    }
}
