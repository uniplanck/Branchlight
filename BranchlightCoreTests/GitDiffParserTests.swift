import BranchlightCore
import Foundation
import XCTest

final class GitDiffParserTests: XCTestCase {
    func testParsesFileHunkAndLineNumbers() throws {
        let diff = """
        diff --git a/tracked.txt b/tracked.txt
        index 422c2b7..11aa222 100644
        --- a/tracked.txt
        +++ b/tracked.txt
        @@ -1,3 +1,4 @@
         one
        -two
        +TWO
         three
        +four
        """

        let files = try GitDiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].displayPath, "tracked.txt")
        XCTAssertEqual(files[0].hunks.count, 1)

        let hunk = files[0].hunks[0]
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.oldCount, 3)
        XCTAssertEqual(hunk.newStart, 1)
        XCTAssertEqual(hunk.newCount, 4)
        XCTAssertEqual(hunk.changedLineCount, 3)

        let deletion = try XCTUnwrap(hunk.lines.first { $0.raw == "-two" })
        XCTAssertEqual(deletion.oldLineNumber, 2)
        XCTAssertNil(deletion.newLineNumber)

        let replacement = try XCTUnwrap(hunk.lines.first { $0.raw == "+TWO" })
        XCTAssertNil(replacement.oldLineNumber)
        XCTAssertEqual(replacement.newLineNumber, 2)

        let appended = try XCTUnwrap(hunk.lines.first { $0.raw == "+four" })
        XCTAssertEqual(appended.newLineNumber, 4)
    }

    func testSelectedLinePatchKeepsUnselectedDeletionAsContext() throws {
        let diff = """
        diff --git a/tracked.txt b/tracked.txt
        index 422c2b7..11aa222 100644
        --- a/tracked.txt
        +++ b/tracked.txt
        @@ -1,3 +1,4 @@
         one
        -two
        +TWO
         three
        +four
        """

        let file = try XCTUnwrap(GitDiffParser.parse(diff).first)
        let hunk = try XCTUnwrap(file.hunks.first)
        let four = try XCTUnwrap(hunk.lines.first { $0.raw == "+four" })

        let patch = try GitPatchBuilder.patch(
            for: file,
            hunk: hunk,
            selectedChangedLineOrdinals: [four.ordinal]
        )

        XCTAssertTrue(patch.contains(" two"))
        XCTAssertFalse(patch.contains("-two"))
        XCTAssertFalse(patch.contains("+TWO"))
        XCTAssertTrue(patch.contains("+four"))
        XCTAssertTrue(patch.contains("@@ -1,3 +1,4 @@"))
    }

    func testPatchBuilderRejectsEmptyChangedLineSelection() throws {
        let diff = """
        diff --git a/tracked.txt b/tracked.txt
        --- a/tracked.txt
        +++ b/tracked.txt
        @@ -1 +1 @@
        -old
        +new
        """

        let file = try XCTUnwrap(GitDiffParser.parse(diff).first)
        let hunk = try XCTUnwrap(file.hunks.first)

        XCTAssertThrowsError(
            try GitPatchBuilder.patch(for: file, hunk: hunk, selectedChangedLineOrdinals: [])
        )
    }
}

final class GitConflictWorkspaceTests: XCTestCase {
    private let engine = SystemGitEngine()

    func testLoadsBaseOursTheirsAndWorkingResultFromActiveConflict() throws {
        let fixture = try makeConflictedFixture(prefix: "BranchlightConflictWorkspace")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let conflict = try engine.conflictFile(at: fixture.repository, path: "tracked.txt")
        XCTAssertEqual(conflict.path, "tracked.txt")
        XCTAssertEqual(conflict.base, "base\n")
        XCTAssertEqual(conflict.ours, "ours\n")
        XCTAssertEqual(conflict.theirs, "theirs\n")
        XCTAssertTrue(conflict.result?.contains("<<<<<<<") == true)
        XCTAssertTrue(conflict.result?.contains("ours") == true)
        XCTAssertTrue(conflict.result?.contains("theirs") == true)
    }

    func testResolveConflictWritesStagesAndAllowsMergeContinue() throws {
        let fixture = try makeConflictedFixture(prefix: "BranchlightConflictResolve")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = try engine.resolveConflict(
            at: fixture.repository,
            path: "tracked.txt",
            result: "resolved\n"
        )
        let tracked = try XCTUnwrap(snapshot.paths.first(where: { $0.path == "tracked.txt" }))
        XCTAssertNotEqual(tracked.kind, .conflicted)
        XCTAssertTrue(tracked.isStaged)
        XCTAssertEqual(
            try String(contentsOf: fixture.repository.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "resolved\n"
        )

        _ = try engine.continueMerge(at: fixture.repository)
        XCTAssertTrue(try engine.status(at: fixture.repository).isClean)
        XCTAssertEqual(
            try String(contentsOf: fixture.repository.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "resolved\n"
        )
    }

    func testRejectsPathThatIsNotCurrentlyConflicted() throws {
        let fixture = try makeFixture(prefix: "BranchlightConflictReject")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try engine.conflictFile(at: fixture.repository, path: "tracked.txt")) { error in
            guard case GitConflictWorkspaceError.notConflicted("tracked.txt") = error else {
                return XCTFail("Expected notConflicted, got \(error)")
            }
        }
    }

    private func makeConflictedFixture(prefix: String) throws -> (root: URL, repository: URL) {
        let fixture = try makeFixture(prefix: prefix)

        try runGit(["checkout", "-b", "side"], at: fixture.repository)
        try "theirs\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: fixture.repository)
        try runGit(["commit", "-m", "side change"], at: fixture.repository)

        try runGit(["checkout", "main"], at: fixture.repository)
        try "ours\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], at: fixture.repository)
        try runGit(["commit", "-m", "main change"], at: fixture.repository)

        guard try runGitAllowingFailure(["merge", "side"], at: fixture.repository) != 0 else {
            throw NSError(domain: "GitConflictWorkspaceTests.Git", code: 99)
        }
        return fixture
    }

    private func makeFixture(prefix: String) throws -> (root: URL, repository: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: repository)
        try runGit(["config", "user.email", "branchlight-conflict@example.invalid"], at: repository)
        try runGit(["config", "user.name", "Branchlight Conflict Tests"], at: repository)
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
                domain: "GitConflictWorkspaceTests.Git",
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
