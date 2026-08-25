import BranchlightCore
import Foundation
import XCTest

final class SystemGitEngineIntegrationTests: XCTestCase {
    private var tempDirectory: URL!
    private var repositoryURL: URL!
    private let engine = SystemGitEngine()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightTests-\(UUID().uuidString)", isDirectory: true)
        repositoryURL = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

        try runGit(["init", "-b", "main"], at: repositoryURL)
        try runGit(["config", "user.email", "branchlight-tests@example.invalid"], at: repositoryURL)
        try runGit(["config", "user.name", "Branchlight Tests"], at: repositoryURL)

        try write("base\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], at: repositoryURL)
        try runGit(["commit", "-m", "initial"], at: repositoryURL)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testCleanRepository() throws {
        let snapshot = try engine.status(at: repositoryURL)
        XCTAssertTrue(snapshot.isClean)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertFalse(snapshot.isDetachedHead)
    }

    func testNewRepositoryBeforeFirstCommitCanStageAndUnstage() throws {
        let newRepository = tempDirectory.appendingPathComponent("new-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: newRepository, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: newRepository)
        try write("first\n", to: newRepository.appendingPathComponent("first.txt"))

        var snapshot = try engine.status(at: newRepository)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.paths.first?.kind, .untracked)

        try engine.stage(at: newRepository, paths: ["first.txt"])
        snapshot = try engine.status(at: newRepository)
        XCTAssertEqual(snapshot.paths.first?.isStaged, true)

        try engine.unstage(at: newRepository, paths: ["first.txt"])
        snapshot = try engine.status(at: newRepository)
        XCTAssertEqual(snapshot.paths.first?.kind, .untracked)
        XCTAssertEqual(snapshot.paths.first?.isStaged, false)
    }

    func testModifiedUntrackedAndStagedStates() throws {
        try write("changed\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try write("new\n", to: repositoryURL.appendingPathComponent("untracked.txt"))
        try write("staged\n", to: repositoryURL.appendingPathComponent("staged.txt"))
        try runGit(["add", "staged.txt"], at: repositoryURL)

        let snapshot = try engine.status(at: repositoryURL)
        let byPath = Dictionary(uniqueKeysWithValues: snapshot.paths.map { ($0.path, $0) })

        XCTAssertEqual(byPath["tracked.txt"]?.kind, .modified)
        XCTAssertEqual(byPath["untracked.txt"]?.kind, .untracked)
        XCTAssertEqual(byPath["staged.txt"]?.kind, .added)
        XCTAssertEqual(byPath["staged.txt"]?.isStaged, true)
    }

    func testDeletedAndRenamedStates() throws {
        try FileManager.default.removeItem(at: repositoryURL.appendingPathComponent("tracked.txt"))
        try write("rename me\n", to: repositoryURL.appendingPathComponent("old.txt"))
        try runGit(["add", "old.txt"], at: repositoryURL)
        try runGit(["commit", "-m", "add rename fixture"], at: repositoryURL)
        try runGit(["mv", "old.txt", "new.txt"], at: repositoryURL)

        let snapshot = try engine.status(at: repositoryURL)
        let kinds = Dictionary(uniqueKeysWithValues: snapshot.paths.map { ($0.path, $0.kind) })

        XCTAssertEqual(kinds["tracked.txt"], .deleted)
        XCTAssertEqual(kinds["new.txt"], .renamed)
    }

    func testDetachedHead() throws {
        try runGit(["checkout", "--detach", "HEAD"], at: repositoryURL)
        let snapshot = try engine.status(at: repositoryURL)
        XCTAssertTrue(snapshot.isDetachedHead)
        XCTAssertFalse(snapshot.branch.isEmpty)
    }

    func testNestedRepositoryResolvesToNearestRoot() throws {
        let nested = repositoryURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: nested)

        let child = nested.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        XCTAssertEqual(
            try engine.repositoryRoot(for: child).standardizedFileURL,
            nested.standardizedFileURL
        )
    }

    func testLinkedWorktreeIsRecognized() throws {
        let worktree = tempDirectory.appendingPathComponent("feature-worktree", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature", worktree.path], at: repositoryURL)

        let snapshot = try engine.status(at: worktree)
        XCTAssertEqual(snapshot.branch, "feature")
        XCTAssertEqual(snapshot.repositoryRoot, worktree.standardizedFileURL.path)
    }

    func testConflictStatus() throws {
        try runGit(["checkout", "-b", "side"], at: repositoryURL)
        try write("side\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], at: repositoryURL)
        try runGit(["commit", "-m", "side change"], at: repositoryURL)

        try runGit(["checkout", "main"], at: repositoryURL)
        try write("main\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], at: repositoryURL)
        try runGit(["commit", "-m", "main change"], at: repositoryURL)

        _ = try runGitAllowingFailure(["merge", "side"], at: repositoryURL)
        let snapshot = try engine.status(at: repositoryURL)

        XCTAssertTrue(snapshot.paths.contains { $0.path == "tracked.txt" && $0.kind == .conflicted })
    }

    func testLargeUntrackedSetRemainsCorrect() throws {
        for index in 0..<250 {
            try write("\(index)\n", to: repositoryURL.appendingPathComponent("bulk-\(index).txt"))
        }

        let snapshot = try engine.status(at: repositoryURL)
        XCTAssertEqual(snapshot.paths.filter { $0.kind == .untracked }.count, 250)
    }

    func testStageUnstageDiffCommitAndHistory() throws {
        try write("base\nchanged\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        let unstagedDiff = try engine.diff(at: repositoryURL, paths: ["tracked.txt"], staged: false)
        XCTAssertTrue(unstagedDiff.contains("+changed"))

        try engine.stage(at: repositoryURL, paths: ["tracked.txt"])
        var snapshot = try engine.status(at: repositoryURL)
        XCTAssertEqual(snapshot.paths.first(where: { $0.path == "tracked.txt" })?.isStaged, true)

        try engine.unstage(at: repositoryURL, paths: ["tracked.txt"])
        snapshot = try engine.status(at: repositoryURL)
        XCTAssertEqual(snapshot.paths.first(where: { $0.path == "tracked.txt" })?.isStaged, false)

        try engine.stage(at: repositoryURL, paths: ["tracked.txt"])
        _ = try engine.commit(at: repositoryURL, message: "engine commit", amend: false)
        let history = try engine.history(at: repositoryURL, limit: 5)
        XCTAssertEqual(history.first?.subject, "engine commit")
        XCTAssertEqual(try engine.status(at: repositoryURL).isClean, true)
    }

    func testStructuredDiffCanStageAndUnstageSingleHunk() throws {
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write(original, to: repositoryURL.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], at: repositoryURL)
        try runGit(["commit", "-m", "multi-hunk fixture"], at: repositoryURL)

        var changedLines = (1...20).map { "line \($0)" }
        changedLines[1] = "line 2 changed"
        changedLines[17] = "line 18 changed"
        try write(changedLines.joined(separator: "\n") + "\n", to: repositoryURL.appendingPathComponent("tracked.txt"))

        let files = try engine.structuredDiff(at: repositoryURL, paths: ["tracked.txt"], staged: false)
        let file = try XCTUnwrap(files.first)
        XCTAssertGreaterThanOrEqual(file.hunks.count, 2)

        let firstHunk = file.hunks[0]
        let patch = GitPatchBuilder.patch(for: file, hunk: firstHunk)
        try engine.applyPatch(at: repositoryURL, patch: patch, reverse: false)

        let stagedDiff = try engine.diff(at: repositoryURL, paths: ["tracked.txt"], staged: true)
        let unstagedDiff = try engine.diff(at: repositoryURL, paths: ["tracked.txt"], staged: false)
        XCTAssertTrue(stagedDiff.contains("line 2 changed"))
        XCTAssertFalse(stagedDiff.contains("line 18 changed"))
        XCTAssertTrue(unstagedDiff.contains("line 18 changed"))

        let stagedFile = try XCTUnwrap(engine.structuredDiff(at: repositoryURL, paths: ["tracked.txt"], staged: true).first)
        let stagedHunk = try XCTUnwrap(stagedFile.hunks.first)
        try engine.applyPatch(
            at: repositoryURL,
            patch: GitPatchBuilder.patch(for: stagedFile, hunk: stagedHunk),
            reverse: true
        )

        XCTAssertTrue(try engine.diff(at: repositoryURL, paths: ["tracked.txt"], staged: true).isEmpty)
        XCTAssertTrue(try engine.diff(at: repositoryURL, paths: ["tracked.txt"], staged: false).contains("line 2 changed"))
    }

    func testSelectedLinePatchStagesOnlySelectedChange() throws {
        try write("one\ntwo\nthree\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], at: repositoryURL)
        try runGit(["commit", "-m", "line staging fixture"], at: repositoryURL)
        try write("one\nTWO\nthree\nfour\n", to: repositoryURL.appendingPathComponent("tracked.txt"))

        let file = try XCTUnwrap(engine.structuredDiff(at: repositoryURL, paths: ["tracked.txt"], staged: false).first)
        let hunk = try XCTUnwrap(file.hunks.first)
        let selectedLine = try XCTUnwrap(hunk.lines.first { $0.raw == "+four" })
        let patch = try GitPatchBuilder.patch(
            for: file,
            hunk: hunk,
            selectedChangedLineOrdinals: [selectedLine.ordinal]
        )

        try engine.applyPatch(at: repositoryURL, patch: patch, reverse: false)

        let stagedDiff = try engine.diff(at: repositoryURL, paths: ["tracked.txt"], staged: true)
        let unstagedDiff = try engine.diff(at: repositoryURL, paths: ["tracked.txt"], staged: false)
        XCTAssertTrue(stagedDiff.contains("+four"))
        XCTAssertFalse(stagedDiff.contains("+TWO"))
        XCTAssertTrue(unstagedDiff.contains("+TWO"))
        XCTAssertFalse(unstagedDiff.contains("+four"))

        let stagedFile = try XCTUnwrap(engine.structuredDiff(at: repositoryURL, paths: ["tracked.txt"], staged: true).first)
        let stagedHunk = try XCTUnwrap(stagedFile.hunks.first)
        let stagedFour = try XCTUnwrap(stagedHunk.lines.first { $0.raw == "+four" })
        let reversePatch = try GitPatchBuilder.patch(
            for: stagedFile,
            hunk: stagedHunk,
            selectedChangedLineOrdinals: [stagedFour.ordinal]
        )
        try engine.applyPatch(at: repositoryURL, patch: reversePatch, reverse: true)

        XCTAssertTrue(try engine.diff(at: repositoryURL, paths: ["tracked.txt"], staged: true).isEmpty)
    }

    func testInProcessGitServiceLoadsRepositoryAndDiff() async throws {
        try write("base\nservice\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        let service = InProcessGitService()

        let load = try await service.loadRepository(at: repositoryURL, includeMetadata: true, historyLimit: 5)
        XCTAssertEqual(load.snapshot.branch, "main")
        XCTAssertNotNil(load.branches)
        XCTAssertNotNil(load.history)

        let files = try await service.structuredDiff(at: repositoryURL, paths: ["tracked.txt"], staged: false)
        XCTAssertEqual(files.first?.displayPath, "tracked.txt")
        XCTAssertTrue(files.first?.hunks.first?.lines.contains(where: { $0.raw == "+service" }) == true)
    }

    func testStashCreateListApplyPopAndDrop() throws {
        try write("base\nchanged\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try write("untracked\n", to: repositoryURL.appendingPathComponent("untracked.txt"))

        _ = try engine.createStash(at: repositoryURL, message: "productivity fixture", includeUntracked: true)
        XCTAssertTrue(try engine.status(at: repositoryURL).isClean)

        let stashes = try engine.stashes(at: repositoryURL)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].reference, "stash@{0}")
        XCTAssertTrue(stashes[0].message.contains("productivity fixture"))

        _ = try engine.applyStash(at: repositoryURL, reference: stashes[0].reference, pop: false)
        var snapshot = try engine.status(at: repositoryURL)
        XCTAssertTrue(snapshot.paths.contains { $0.path == "tracked.txt" && $0.kind == .modified })
        XCTAssertTrue(snapshot.paths.contains { $0.path == "untracked.txt" && $0.kind == .untracked })
        XCTAssertEqual(try engine.stashes(at: repositoryURL).count, 1)

        try runGit(["reset", "--hard", "HEAD"], at: repositoryURL)
        try FileManager.default.removeItem(at: repositoryURL.appendingPathComponent("untracked.txt"))
        _ = try engine.applyStash(at: repositoryURL, reference: "stash@{0}", pop: true)
        snapshot = try engine.status(at: repositoryURL)
        XCTAssertTrue(snapshot.paths.contains { $0.path == "tracked.txt" && $0.kind == .modified })
        XCTAssertTrue(snapshot.paths.contains { $0.path == "untracked.txt" && $0.kind == .untracked })
        XCTAssertTrue(try engine.stashes(at: repositoryURL).isEmpty)

        try runGit(["reset", "--hard", "HEAD"], at: repositoryURL)
        try FileManager.default.removeItem(at: repositoryURL.appendingPathComponent("untracked.txt"))
        try write("drop me\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        _ = try engine.createStash(at: repositoryURL, message: "drop fixture", includeUntracked: false)
        _ = try engine.dropStash(at: repositoryURL, reference: "stash@{0}")
        XCTAssertTrue(try engine.stashes(at: repositoryURL).isEmpty)
        XCTAssertThrowsError(try engine.applyStash(at: repositoryURL, reference: "--all", pop: false))
    }

    func testFileHistoryAndBlame() throws {
        try write("base\nsecond\n", to: repositoryURL.appendingPathComponent("tracked.txt"))
        try runGit(["add", "tracked.txt"], at: repositoryURL)
        try runGit(["commit", "-m", "extend tracked"], at: repositoryURL)

        let fileHistory = try engine.fileHistory(at: repositoryURL, path: "tracked.txt", limit: 10)
        XCTAssertEqual(fileHistory.first?.subject, "extend tracked")
        XCTAssertTrue(fileHistory.contains { $0.subject == "initial" })

        let blame = try engine.blame(at: repositoryURL, path: "tracked.txt")
        XCTAssertEqual(blame.count, 2)
        XCTAssertEqual(blame[1].lineNumber, 2)
        XCTAssertEqual(blame[1].content, "second")
        XCTAssertEqual(blame[1].author, "Branchlight Tests")
        XCTAssertFalse(blame[1].commitHash.isEmpty)
    }

    func testWorktreeListAddExistingAndNewBranchRemove() throws {
        try runGit(["branch", "feature"], at: repositoryURL)
        let featurePath = tempDirectory.appendingPathComponent("feature-worktree", isDirectory: true)
        _ = try engine.addWorktree(at: repositoryURL, path: featurePath, branch: "feature")

        var worktrees = try engine.worktrees(at: repositoryURL)
        XCTAssertTrue(worktrees.contains { $0.path == repositoryURL.standardizedFileURL.path && $0.branch == "main" })
        XCTAssertTrue(worktrees.contains { $0.path == featurePath.standardizedFileURL.path && $0.branch == "feature" })
        XCTAssertEqual(try engine.status(at: featurePath).branch, "feature")

        _ = try engine.removeWorktree(at: repositoryURL, path: featurePath)
        worktrees = try engine.worktrees(at: repositoryURL)
        XCTAssertFalse(worktrees.contains { $0.path == featurePath.standardizedFileURL.path })
        XCTAssertFalse(FileManager.default.fileExists(atPath: featurePath.path))

        let newPath = tempDirectory.appendingPathComponent("topic-worktree", isDirectory: true)
        _ = try engine.addWorktree(at: repositoryURL, path: newPath, newBranch: "topic", startPoint: "HEAD")
        XCTAssertEqual(try engine.status(at: newPath).branch, "topic")
        XCTAssertTrue(try engine.worktrees(at: repositoryURL).contains { $0.path == newPath.standardizedFileURL.path && $0.branch == "topic" })
        _ = try engine.removeWorktree(at: repositoryURL, path: newPath)
    }

    func testBranchesAndSwitch() throws {
        try runGit(["branch", "feature"], at: repositoryURL)
        var branches = try engine.branches(at: repositoryURL)
        XCTAssertTrue(branches.contains { $0.name == "main" && $0.isCurrent })
        XCTAssertTrue(branches.contains { $0.name == "feature" && !$0.isCurrent })

        try engine.switchBranch(at: repositoryURL, name: "feature")
        branches = try engine.branches(at: repositoryURL)
        XCTAssertTrue(branches.contains { $0.name == "feature" && $0.isCurrent })
        XCTAssertEqual(try engine.status(at: repositoryURL).branch, "feature")
    }

    func testLocalRemoteFetchPullAndPush() throws {
        let remote = tempDirectory.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try runGit(["init", "--bare"], at: remote)
        try runGit(["remote", "add", "origin", remote.path], at: repositoryURL)
        try runGit(["push", "-u", "origin", "main"], at: repositoryURL)

        _ = try engine.fetch(at: repositoryURL)
        _ = try engine.push(at: repositoryURL)

        let collaborator = tempDirectory.appendingPathComponent("collaborator", isDirectory: true)
        try runGit(["clone", remote.path, collaborator.path], at: tempDirectory)
        try runGit(["config", "user.email", "branchlight-collaborator@example.invalid"], at: collaborator)
        try runGit(["config", "user.name", "Branchlight Collaborator"], at: collaborator)
        try runGit(["checkout", "main"], at: collaborator)
        try write("remote\n", to: collaborator.appendingPathComponent("remote.txt"))
        try runGit(["add", "remote.txt"], at: collaborator)
        try runGit(["commit", "-m", "remote commit"], at: collaborator)
        try runGit(["push", "origin", "main"], at: collaborator)

        _ = try engine.pullFastForwardOnly(at: repositoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryURL.appendingPathComponent("remote.txt").path))
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func runGit(_ arguments: [String], at directory: URL) throws -> String {
        let result = try runGitAllowingFailure(arguments, at: directory)
        guard result.status == 0 else {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
            throw NSError(domain: "BranchlightTests.Git", code: Int(result.status))
        }
        return result.stdout
    }

    private func runGitAllowingFailure(
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
