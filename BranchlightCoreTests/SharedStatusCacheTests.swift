import BranchlightCore
import Foundation
import XCTest

final class SharedStatusCacheTests: XCTestCase {
    private func makeCache() throws -> (SharedStatusCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightSharedStatusCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SharedStatusCache(storageDirectoryURL: directory), directory)
    }

    func testPersistsSnapshotAndMonitoredRoot() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = GitStatusSnapshot(
            repositoryRoot: "/tmp/example-repo",
            branch: "main",
            isDetachedHead: false,
            paths: [
                GitPathStatus(
                    path: "Sources/File.swift",
                    indexCode: " ",
                    workTreeCode: "M",
                    kind: .modified
                )
            ]
        )

        _ = try cache.replaceSnapshot(snapshot)
        let reloaded = cache.load()

        XCTAssertEqual(reloaded.monitoredRoots, ["/tmp/example-repo"])
        XCTAssertEqual(reloaded.snapshots["/tmp/example-repo"]?.branch, "main")
        XCTAssertEqual(reloaded.statusKind(forAbsolutePath: "/tmp/example-repo/Sources"), .modified)
    }

    func testPersistsRepositoryIntelligenceWithSnapshotAtomically() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = "/tmp/intelligent-repo"
        let snapshot = GitStatusSnapshot(
            repositoryRoot: root,
            branch: "feature/runtime",
            isDetachedHead: false,
            paths: [
                GitPathStatus(path: "A.swift", indexCode: "M", workTreeCode: " ", kind: .staged),
                GitPathStatus(path: "B.swift", indexCode: " ", workTreeCode: "M", kind: .modified)
            ]
        )
        let intelligence = GitRepositoryIntelligence(
            identity: GitRepositoryIdentity(
                workingTreeRoot: root,
                gitDirectory: "\(root)/.git",
                commonGitDirectory: "\(root)/.git"
            ),
            branch: "feature/runtime",
            upstream: "origin/feature/runtime",
            tracking: GitAheadBehind(ahead: 2, behind: 1),
            isDetachedHead: false,
            operationMode: .rebasing,
            changedCount: 2,
            stagedCount: 1,
            untrackedCount: 0,
            conflictCount: 0,
            capturedAt: Date(timeIntervalSince1970: 456)
        )

        let written = try cache.replaceRepositoryState(snapshot: snapshot, intelligence: intelligence)
        let reloaded = cache.load()

        XCTAssertEqual(written.revision, 1)
        XCTAssertEqual(reloaded.snapshots[root]?.branch, "feature/runtime")
        XCTAssertEqual(reloaded.intelligence(forRepositoryRoot: root), intelligence)
        XCTAssertEqual(reloaded.intelligence(forRepositoryRoot: root)?.tracking?.summary, "↑2 ↓1")
        XCTAssertEqual(reloaded.monitoredRoots, [root])
    }

    func testPendingFinderPathIsConsumedOnce() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        cache.setPendingOpenPath("/tmp/example-repo/File.swift")
        XCTAssertEqual(cache.consumePendingOpenPath(), "/tmp/example-repo/File.swift")
        XCTAssertNil(cache.consumePendingOpenPath())
    }

    func testFinderIntegrationCompatibilityWarnsForCloudStorage() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let cloudRepository = URL(fileURLWithPath: "/Users/tester/Library/CloudStorage/Dropbox/project", isDirectory: true)
        let localRepository = URL(fileURLWithPath: "/Users/tester/Projects/project", isDirectory: true)

        XCTAssertNotNil(FinderIntegrationCompatibility.warning(for: cloudRepository, homeDirectoryURL: home))
        XCTAssertNil(FinderIntegrationCompatibility.warning(for: localRepository, homeDirectoryURL: home))
    }

    func testPendingFinderIntentIsConsumedOnce() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let intent = FinderIntent(
            action: .stage,
            repositoryRoot: "/tmp/example-repo",
            paths: ["Sources/File.swift"],
            requestedAt: Date(timeIntervalSince1970: 123)
        )
        try cache.setPendingFinderIntent(intent)

        XCTAssertEqual(cache.consumePendingFinderIntent(), intent)
        XCTAssertNil(cache.consumePendingFinderIntent())
    }

    func testMigratesLegacyEnvelopeWithoutUserDefaultsAccess() throws {
        let (cacheDirectory, legacyPreferencesURL) = try makeMigrationFixture()
        defer { try? FileManager.default.removeItem(at: cacheDirectory.deletingLastPathComponent()) }

        let snapshot = GitStatusSnapshot(
            repositoryRoot: "/tmp/legacy-repo",
            branch: "legacy",
            isDetachedHead: false,
            paths: []
        )
        let envelope = StatusCacheEnvelope(
            revision: 41,
            monitoredRoots: ["/tmp/legacy-repo"],
            snapshots: ["/tmp/legacy-repo": snapshot]
        )
        let legacyPlist: [String: Any] = ["statusCacheEnvelopeV1": try JSONEncoder().encode(envelope)]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: legacyPlist,
            format: .binary,
            options: 0
        )
        try plistData.write(to: legacyPreferencesURL, options: .atomic)

        let cache = SharedStatusCache(
            storageDirectoryURL: cacheDirectory,
            legacyPreferencesURL: legacyPreferencesURL
        )
        let migrated = cache.load()
        XCTAssertEqual(migrated.revision, 41)
        XCTAssertEqual(migrated.monitoredRoots, ["/tmp/legacy-repo"])
        XCTAssertNil(migrated.repositoryIntelligence)

        try FileManager.default.removeItem(at: legacyPreferencesURL)
        let reloaded = cache.load()
        XCTAssertEqual(reloaded.revision, 41)
        XCTAssertEqual(reloaded.monitoredRoots, ["/tmp/legacy-repo"])
    }

    private func makeMigrationFixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightLegacyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDirectory = root.appendingPathComponent("Shared", isDirectory: true)
        let preferencesDirectory = root.appendingPathComponent("Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        return (cacheDirectory, preferencesDirectory.appendingPathComponent("legacy.plist"))
    }
}

final class GitSafetyPreflightTests: XCTestCase {
    func testCleanFetchIsSafeAndProceedable() {
        let report = GitSafetyPreflight.evaluate(intent: .fetch, intelligence: makeIntelligence())
        XCTAssertEqual(report.risk, .safe)
        XCTAssertTrue(report.canProceed)
        XCTAssertFalse(report.requiresConfirmation)
        XCTAssertTrue(report.signals.isEmpty)
    }

    func testDivergedDirtyPullRequiresConfirmation() {
        let report = GitSafetyPreflight.evaluate(
            intent: .pull,
            intelligence: makeIntelligence(
                upstream: "origin/main",
                tracking: GitAheadBehind(ahead: 2, behind: 3),
                changedCount: 2,
                untrackedCount: 1
            )
        )

        XCTAssertEqual(report.risk, .caution)
        XCTAssertTrue(report.canProceed)
        XCTAssertTrue(report.requiresConfirmation)
        XCTAssertTrue(report.signals.contains(.dirtyWorkingTree))
        XCTAssertTrue(report.signals.contains(.untrackedFiles))
        XCTAssertTrue(report.signals.contains(.upstreamDiverged))
        XCTAssertEqual(report.warnings.count, 3)
    }

    func testBranchSwitchIsBlockedDuringConflictedMerge() {
        let report = GitSafetyPreflight.evaluate(
            intent: .switchBranch,
            intelligence: makeIntelligence(operationMode: .merging, changedCount: 1, conflictCount: 1)
        )

        XCTAssertFalse(report.canProceed)
        XCTAssertEqual(report.risk, .caution)
        XCTAssertTrue(report.signals.contains(.operationInProgress))
        XCTAssertTrue(report.signals.contains(.conflicts))
        XCTAssertEqual(report.blockingReasons.count, 2)
    }

    func testIrreversibleRemovalIsAlwaysDestructive() {
        let stashDrop = GitSafetyPreflight.evaluate(intent: .stashDrop, intelligence: makeIntelligence())
        let worktreeRemove = GitSafetyPreflight.evaluate(intent: .worktreeRemove, intelligence: makeIntelligence())
        let resetHard = GitSafetyPreflight.evaluate(intent: .resetHard, intelligence: makeIntelligence())

        XCTAssertEqual(stashDrop.risk, .destructive)
        XCTAssertEqual(worktreeRemove.risk, .destructive)
        XCTAssertEqual(resetHard.risk, .destructive)
        XCTAssertTrue(stashDrop.requiresConfirmation)
        XCTAssertTrue(worktreeRemove.requiresConfirmation)
        XCTAssertTrue(resetHard.requiresConfirmation)
    }

    private func makeIntelligence(
        upstream: String? = "origin/main",
        tracking: GitAheadBehind? = GitAheadBehind(ahead: 0, behind: 0),
        isDetachedHead: Bool = false,
        operationMode: GitRepositoryOperationMode = .normal,
        changedCount: Int = 0,
        stagedCount: Int = 0,
        untrackedCount: Int = 0,
        conflictCount: Int = 0
    ) -> GitRepositoryIntelligence {
        GitRepositoryIntelligence(
            identity: GitRepositoryIdentity(
                workingTreeRoot: "/tmp/repo",
                gitDirectory: "/tmp/repo/.git",
                commonGitDirectory: "/tmp/repo/.git"
            ),
            branch: "main",
            upstream: upstream,
            tracking: tracking,
            isDetachedHead: isDetachedHead,
            operationMode: operationMode,
            changedCount: changedCount,
            stagedCount: stagedCount,
            untrackedCount: untrackedCount,
            conflictCount: conflictCount,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

final class GitRecoveryPlannerTests: XCTestCase {
    func testWholePathStageRequiresMatchingPostCheckpoint() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .stage, affectedPaths: ["A.swift", "B.swift"]),
            preCheckpoint: checkpoint(head: "abc", branch: "main", index: "tree-before"),
            postCheckpoint: checkpoint(head: "abc", branch: "main", index: "tree-after")
        )
        let plan = GitRecoveryPlanner.plan(for: record)

        XCTAssertEqual(plan.availability, .validationRequired)
        XCTAssertEqual(plan.inverseIntent, .unstage)
        XCTAssertEqual(plan.affectedPaths, ["A.swift", "B.swift"])
        XCTAssertEqual(plan.expectedCurrentHead, "abc")
        XCTAssertEqual(plan.expectedCurrentIndexTree, "tree-after")
    }

    func testStageWithoutCheckpointIsUnavailable() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .stage, affectedPaths: ["A.swift"])
        )
        XCTAssertEqual(GitRecoveryPlanner.plan(for: record).availability, .unavailable)
    }

    func testPatchStageIsUnavailableEvenWithCheckpoint() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .stage, target: "patch"),
            preCheckpoint: checkpoint(head: "abc", branch: "main", index: "before"),
            postCheckpoint: checkpoint(head: "abc", branch: "main", index: "after")
        )
        XCTAssertEqual(GitRecoveryPlanner.plan(for: record).availability, .unavailable)
    }

    func testBranchSwitchCanReturnToCheckpointedPreviousBranchAfterValidation() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .switchBranch, target: "feature"),
            preCheckpoint: checkpoint(head: "aaa", branch: "main", index: "tree"),
            postCheckpoint: checkpoint(head: "bbb", branch: "feature", index: "tree")
        )
        let plan = GitRecoveryPlanner.plan(for: record)

        XCTAssertEqual(plan.availability, .validationRequired)
        XCTAssertEqual(plan.inverseIntent, .switchBranch)
        XCTAssertEqual(plan.target, "main")
        XCTAssertEqual(plan.expectedCurrentHead, "bbb")
    }

    func testCommitRecoveryUsesRevertNotHistoryRewrite() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .commit),
            preCheckpoint: checkpoint(head: "before", branch: "main", index: "tree-before"),
            postCheckpoint: checkpoint(head: "created", branch: "main", index: "tree-after")
        )
        let plan = GitRecoveryPlanner.plan(for: record)

        XCTAssertEqual(plan.availability, .validationRequired)
        XCTAssertEqual(plan.inverseIntent, .revert)
        XCTAssertEqual(plan.target, "created")
        XCTAssertEqual(plan.expectedCurrentHead, "created")
    }

    func testWorktreeCreationProducesValidatedRemovalCandidate() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(
                intent: .worktreeAdd,
                reference: "feature/recovery",
                target: "/tmp/recovery-worktree"
            )
        )
        let plan = GitRecoveryPlanner.plan(for: record)
        XCTAssertEqual(plan.availability, .validationRequired)
        XCTAssertEqual(plan.inverseIntent, .worktreeRemove)
        XCTAssertEqual(plan.target, "/tmp/recovery-worktree")
    }

    func testDestructiveOrFailedOperationsNeverOfferRecoveryCandidate() {
        let dropped = GitRecoveryPlanner.plan(
            for: makeRecord(descriptor: GitOperationDescriptor(intent: .stashDrop, reference: "stash@{0}"))
        )
        let failed = GitRecoveryPlanner.plan(
            for: makeRecord(
                descriptor: GitOperationDescriptor(intent: .stage, affectedPaths: ["A.swift"]),
                state: .failed
            )
        )

        XCTAssertEqual(dropped.availability, .unavailable)
        XCTAssertEqual(failed.availability, .unavailable)
        XCTAssertNil(dropped.inverseIntent)
        XCTAssertNil(failed.inverseIntent)
    }

    private func makeRecord(
        descriptor: GitOperationDescriptor?,
        preCheckpoint: GitRepositoryCheckpoint? = nil,
        postCheckpoint: GitRepositoryCheckpoint? = nil,
        state: GitOperationState = .succeeded
    ) -> GitOperationRecord {
        GitOperationRecord(
            id: UUID(),
            repository: GitRepositoryIdentity(
                workingTreeRoot: "/tmp/repo",
                gitDirectory: "/tmp/repo/.git",
                commonGitDirectory: "/tmp/repo/.git"
            ),
            label: "test",
            descriptor: descriptor,
            preCheckpoint: preCheckpoint,
            postCheckpoint: postCheckpoint,
            state: state,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            errorDescription: state == .failed ? "failed" : nil
        )
    }

    private func checkpoint(head: String, branch: String, index: String) -> GitRepositoryCheckpoint {
        GitRepositoryCheckpoint(
            headCommit: head,
            branch: branch,
            isDetachedHead: false,
            indexTree: index,
            operationMode: .normal,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
