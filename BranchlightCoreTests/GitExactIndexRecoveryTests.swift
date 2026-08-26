import BranchlightCore
import Foundation
import XCTest

final class GitExactIndexRecoveryTests: XCTestCase {
    func testStageRecoveryRestoresExactPriorPartialIndex() async throws {
        let fixture = try makeFixture(prefix: "BranchlightExactStageRecovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let service = InProcessGitService()
        try "tracked modified\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "other modified\n".write(
            to: fixture.repository.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await service.stage(at: fixture.repository, paths: ["other.txt"])
        let exactPreIndex = try indexData(in: fixture.repository)

        try await service.stage(at: fixture.repository, paths: ["tracked.txt"])
        let stageRecords = await service.recentOperations(limit: 4)
        let sourceRecord = try XCTUnwrap(
            stageRecords.first(where: {
                $0.descriptor?.intent == .stage && $0.descriptor?.affectedPaths == ["tracked.txt"]
            })
        )
        XCTAssertNotNil(sourceRecord.preCheckpoint?.indexSnapshot)
        XCTAssertNotNil(sourceRecord.postCheckpoint?.indexSnapshot)
        XCTAssertNotEqual(sourceRecord.preCheckpoint?.indexSnapshot, sourceRecord.postCheckpoint?.indexSnapshot)

        let action = try await service.executeRecovery(for: sourceRecord)
        guard case .restoreIndex(let restoredSnapshot) = action else {
            return XCTFail("Expected exact index restoration, got \(action)")
        }
        XCTAssertEqual(restoredSnapshot, sourceRecord.preCheckpoint?.indexSnapshot)
        XCTAssertEqual(try indexData(in: fixture.repository), exactPreIndex)

        XCTAssertEqual(
            try gitOutput(["diff", "--cached", "--name-only"], at: fixture.repository),
            "other.txt"
        )
        XCTAssertTrue(
            try gitOutput(["diff", "--name-only"], at: fixture.repository)
                .split(separator: "\n")
                .contains("tracked.txt")
        )
    }

    func testUnstageRecoveryRestoresExactPriorIndex() async throws {
        let fixture = try makeFixture(prefix: "BranchlightExactUnstageRecovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let service = InProcessGitService()
        try "tracked modified\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "other modified\n".write(
            to: fixture.repository.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await service.stage(at: fixture.repository, paths: ["tracked.txt", "other.txt"])
        let exactPreIndex = try indexData(in: fixture.repository)

        try await service.unstage(at: fixture.repository, paths: ["tracked.txt"])
        let unstageRecords = await service.recentOperations(limit: 4)
        let sourceRecord = try XCTUnwrap(
            unstageRecords.first(where: {
                $0.descriptor?.intent == .unstage && $0.descriptor?.affectedPaths == ["tracked.txt"]
            })
        )

        _ = try await service.executeRecovery(for: sourceRecord)
        XCTAssertEqual(try indexData(in: fixture.repository), exactPreIndex)

        let cached = try gitOutput(["diff", "--cached", "--name-only"], at: fixture.repository)
            .split(separator: "\n")
            .map(String.init)
            .sorted()
        XCTAssertEqual(cached, ["other.txt", "tracked.txt"])
    }

    func testStageRecoveryPreservesIntentToAddIndexBits() async throws {
        let fixture = try makeFixture(prefix: "BranchlightIntentToAddRecovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let service = InProcessGitService()
        try "intent to add\n".write(
            to: fixture.repository.appendingPathComponent("future.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "-N", "future.txt"], at: fixture.repository)
        let exactPreIndex = try indexData(in: fixture.repository)

        try "tracked modified\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await service.stage(at: fixture.repository, paths: ["tracked.txt"])
        let stageRecords = await service.recentOperations(limit: 2)
        let sourceRecord = try XCTUnwrap(
            stageRecords.first(where: {
                $0.descriptor?.intent == .stage && $0.descriptor?.affectedPaths == ["tracked.txt"]
            })
        )

        _ = try await service.executeRecovery(for: sourceRecord)
        XCTAssertEqual(try indexData(in: fixture.repository), exactPreIndex)
        XCTAssertTrue(
            try gitOutput(["ls-files", "--debug", "future.txt"], at: fixture.repository)
                .contains("future.txt")
        )
        XCTAssertEqual(try gitOutput(["diff", "--cached", "--name-only"], at: fixture.repository), "")
    }

    func testExactRecoveryRejectsWhenIndexChangedAfterSourceOperation() async throws {
        let fixture = try makeFixture(prefix: "BranchlightExactRecoveryReject")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let service = InProcessGitService()
        try "tracked modified\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "other modified\n".write(
            to: fixture.repository.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await service.stage(at: fixture.repository, paths: ["tracked.txt"])
        let stageRecords = await service.recentOperations(limit: 2)
        let sourceRecord = try XCTUnwrap(
            stageRecords.first(where: {
                $0.descriptor?.intent == .stage && $0.descriptor?.affectedPaths == ["tracked.txt"]
            })
        )

        try runGit(["add", "other.txt"], at: fixture.repository)

        do {
            _ = try await service.executeRecovery(for: sourceRecord)
            XCTFail("Expected exact recovery to reject an index that changed after the source operation.")
        } catch let error as GitRecoveryValidationError {
            switch error {
            case .rejected(let issues):
                XCTAssertTrue(issues.contains(.indexChanged))
            }
        }
    }

    private func makeFixture(prefix: String) throws -> (root: URL, repository: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: repository)
        try runGit(["config", "user.email", "branchlight-index@example.invalid"], at: repository)
        try runGit(["config", "user.name", "Branchlight Index Tests"], at: repository)
        try "base\n".write(
            to: repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "other base\n".write(
            to: repository.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt", "other.txt"], at: repository)
        try runGit(["commit", "-m", "initial"], at: repository)
        return (root, repository)
    }

    private func indexData(in repository: URL) throws -> Data {
        try Data(contentsOf: repository.appendingPathComponent(".git/index"))
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let result = try runGitResult(arguments, at: directory)
        guard result.status == 0 else {
            throw NSError(
                domain: "GitExactIndexRecoveryTests.Git",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        let result = try runGitResult(arguments, at: directory)
        guard result.status == 0 else {
            throw NSError(
                domain: "GitExactIndexRecoveryTests.Git",
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
