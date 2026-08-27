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

        let requestedAt = Date(timeIntervalSince1970: 123)
        let intent = FinderIntent(
            action: .stage,
            repositoryRoot: "/tmp/example-repo",
            paths: ["Sources/File.swift"],
            requestedAt: requestedAt
        )
        try cache.setPendingFinderIntent(intent)

        let now = requestedAt.addingTimeInterval(30)
        XCTAssertEqual(cache.consumePendingFinderIntent(now: now), intent)
        XCTAssertNil(cache.consumePendingFinderIntent(now: now))
    }

    func testStaleFinderIntentIsConsumedWithoutBeingReturned() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 10_000)
        let intent = FinderIntent(
            action: .unstage,
            repositoryRoot: "/tmp/example-repo",
            paths: ["Sources/File.swift"],
            requestedAt: now.addingTimeInterval(-FinderIntent.defaultMaximumAge - 1)
        )
        try cache.setPendingFinderIntent(intent)

        XCTAssertNil(cache.consumePendingFinderIntent(now: now))
        XCTAssertNil(cache.consumePendingFinderIntent(now: now))
    }

    func testFinderIntentWithinFreshnessWindowIsReturned() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 20_000)
        let intent = FinderIntent(
            action: .stage,
            repositoryRoot: "/tmp/example-repo",
            paths: ["A.swift"],
            requestedAt: now.addingTimeInterval(-FinderIntent.defaultMaximumAge + 1)
        )
        try cache.setPendingFinderIntent(intent)

        XCTAssertEqual(cache.consumePendingFinderIntent(now: now), intent)
    }

    func testFinderIntentWithExcessiveFutureClockSkewIsRejected() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 30_000)
        let intent = FinderIntent(
            action: .stage,
            repositoryRoot: "/tmp/example-repo",
            paths: ["A.swift"],
            requestedAt: now.addingTimeInterval(FinderIntent.maximumFutureClockSkew + 1)
        )
        try cache.setPendingFinderIntent(intent)

        XCTAssertNil(cache.consumePendingFinderIntent(now: now))
    }

    func testCorruptEnvelopeIsQuarantinedAndCacheRecovers() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let envelopeURL = directory.appendingPathComponent("status-cache-envelope-v1.json")
        try Data("{not-valid-json".utf8).write(to: envelopeURL, options: .atomic)

        let recovered = cache.load()
        XCTAssertEqual(recovered.revision, 0)
        XCTAssertTrue(recovered.snapshots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))

        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("status-cache-envelope-v1.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)

        let snapshot = GitStatusSnapshot(
            repositoryRoot: "/tmp/recovered",
            branch: "main",
            isDetachedHead: false,
            paths: []
        )
        _ = try cache.replaceSnapshot(snapshot)
        XCTAssertEqual(cache.load().snapshots["/tmp/recovered"]?.branch, "main")
    }

    func testCorruptPendingIntentIsQuarantinedAndIgnored() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let intentURL = directory.appendingPathComponent("pending-finder-intent-v1.json")
        try Data([0xFF, 0x00, 0x13]).write(to: intentURL, options: .atomic)

        XCTAssertNil(cache.consumePendingFinderIntent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("pending-finder-intent-v1.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
    }

    func testCorruptBackupsAreBounded() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let envelopeURL = directory.appendingPathComponent("status-cache-envelope-v1.json")
        for index in 0..<6 {
            try Data("bad-json-\(index)".utf8).write(to: envelopeURL, options: .atomic)
            _ = cache.load()
        }

        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("status-cache-envelope-v1.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 3)
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
            preCheckpoint: checkpoint(
                head: "abc",
                branch: "main",
                index: "tree-before",
                exactIndex: "index-before"
            ),
            postCheckpoint: checkpoint(
                head: "abc",
                branch: "main",
                index: "tree-after",
                exactIndex: "index-after"
            )
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

    func testPatchStageIsRecoverableWithExactIndexCheckpoint() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .stage, target: "patch"),
            preCheckpoint: checkpoint(
                head: "abc",
                branch: "main",
                index: "before",
                exactIndex: "index-before"
            ),
            postCheckpoint: checkpoint(
                head: "abc",
                branch: "main",
                index: "after",
                exactIndex: "index-after"
            )
        )
        let plan = GitRecoveryPlanner.plan(for: record)
        XCTAssertEqual(plan.availability, .validationRequired)
        XCTAssertEqual(plan.inverseIntent, .unstage)
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

    private func checkpoint(
        head: String,
        branch: String,
        index: String,
        exactIndex: String? = nil
    ) -> GitRepositoryCheckpoint {
        GitRepositoryCheckpoint(
            headCommit: head,
            branch: branch,
            isDetachedHead: false,
            indexTree: index,
            indexSnapshot: exactIndex.map {
                GitIndexSnapshot(data: Data($0.utf8), fileMode: 0o100644)
            },
            operationMode: .normal,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

final class GitRecoveryValidatorTests: XCTestCase {
    func testMatchingCommitRecoveryProducesRevertAction() throws {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .commit),
            pre: checkpoint(head: "before", branch: "main", index: "tree-before"),
            post: checkpoint(head: "created", branch: "main", index: "tree-after")
        )
        let plan = GitRecoveryPlanner.plan(for: record)
        let status = cleanStatus(branch: "main")

        let validation = GitRecoveryValidator.validate(
            plan: plan,
            sourceRecord: record,
            currentCheckpoint: checkpoint(head: "created", branch: "main", index: "tree-after"),
            currentStatus: status
        )
        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(
            try GitRecoveryValidator.validatedAction(
                plan: plan,
                sourceRecord: record,
                currentCheckpoint: checkpoint(head: "created", branch: "main", index: "tree-after"),
                currentStatus: status
            ),
            .revertCommit("created")
        )
    }

    func testChangedHeadAndBranchRejectRecovery() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .switchBranch, target: "feature"),
            pre: checkpoint(head: "aaa", branch: "main", index: "tree"),
            post: checkpoint(head: "bbb", branch: "feature", index: "tree")
        )
        let plan = GitRecoveryPlanner.plan(for: record)
        let validation = GitRecoveryValidator.validate(
            plan: plan,
            sourceRecord: record,
            currentCheckpoint: checkpoint(head: "ccc", branch: "other", index: "tree"),
            currentStatus: cleanStatus(branch: "other")
        )

        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.issues.contains(.headChanged))
        XCTAssertTrue(validation.issues.contains(.branchChanged))
    }

    func testDirtyWorkingTreeRejectsBranchSwitchRecovery() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .switchBranch, target: "feature"),
            pre: checkpoint(head: "aaa", branch: "main", index: "tree"),
            post: checkpoint(head: "bbb", branch: "feature", index: "tree")
        )
        let plan = GitRecoveryPlanner.plan(for: record)
        let dirty = GitStatusSnapshot(
            repositoryRoot: "/tmp/repo",
            branch: "feature",
            isDetachedHead: false,
            paths: [GitPathStatus(path: "A.swift", indexCode: " ", workTreeCode: "M", kind: .modified)]
        )

        let validation = GitRecoveryValidator.validate(
            plan: plan,
            sourceRecord: record,
            currentCheckpoint: checkpoint(head: "bbb", branch: "feature", index: "tree"),
            currentStatus: dirty
        )
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.issues.contains(.workingTreeNotClean))
    }

    func testOperationInProgressRejectsRecovery() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .commit),
            pre: checkpoint(head: "before", branch: "main", index: "tree-before"),
            post: checkpoint(head: "created", branch: "main", index: "tree-after")
        )
        let plan = GitRecoveryPlanner.plan(for: record)
        let current = GitRepositoryCheckpoint(
            headCommit: "created",
            branch: "main",
            isDetachedHead: false,
            indexTree: "tree-after",
            operationMode: .rebasing
        )

        let validation = GitRecoveryValidator.validate(
            plan: plan,
            sourceRecord: record,
            currentCheckpoint: current,
            currentStatus: cleanStatus(branch: "main")
        )
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.issues.contains(.operationInProgress))
    }

    func testStageRecoveryIsUnavailableWithoutExactIndexCheckpoint() {
        let record = makeRecord(
            descriptor: GitOperationDescriptor(intent: .stage, affectedPaths: ["A.swift"]),
            pre: checkpoint(head: "abc", branch: "main", index: "before"),
            post: checkpoint(head: "abc", branch: "main", index: "after")
        )
        let plan = GitRecoveryPlanner.plan(for: record)
        XCTAssertEqual(plan.availability, .unavailable)

        let validation = GitRecoveryValidator.validate(
            plan: plan,
            sourceRecord: record,
            currentCheckpoint: checkpoint(head: "abc", branch: "main", index: "after"),
            currentStatus: cleanStatus(branch: "main")
        )
        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.issues, [.unavailablePlan])
    }

    func testMutationAdmissionSeparatesAllowedConfirmationAndBlocked() {
        let safe = GitPreflightReport(
            intent: .fetch,
            risk: .safe,
            signals: [],
            blockingReasons: [],
            warnings: []
        )
        XCTAssertEqual(GitMutationAdmission(report: safe).state, .allowed)

        let caution = GitPreflightReport(
            intent: .pull,
            risk: .caution,
            signals: [.dirtyWorkingTree],
            blockingReasons: [],
            warnings: ["dirty"]
        )
        XCTAssertEqual(GitMutationAdmission(report: caution).state, .confirmationRequired)
        XCTAssertEqual(GitMutationAdmission(report: caution, confirmationProvided: true).state, .allowed)

        let blocked = GitPreflightReport(
            intent: .switchBranch,
            risk: .caution,
            signals: [.operationInProgress],
            blockingReasons: ["operation in progress"],
            warnings: []
        )
        XCTAssertEqual(GitMutationAdmission(report: blocked, confirmationProvided: true).state, .blocked)
    }

    private func makeRecord(
        descriptor: GitOperationDescriptor,
        pre: GitRepositoryCheckpoint,
        post: GitRepositoryCheckpoint
    ) -> GitOperationRecord {
        GitOperationRecord(
            id: UUID(),
            repository: GitRepositoryIdentity(
                workingTreeRoot: "/tmp/repo",
                gitDirectory: "/tmp/repo/.git",
                commonGitDirectory: "/tmp/repo/.git"
            ),
            label: "recovery-test",
            descriptor: descriptor,
            preCheckpoint: pre,
            postCheckpoint: post,
            state: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            errorDescription: nil
        )
    }

    private func checkpoint(
        head: String,
        branch: String,
        index: String
    ) -> GitRepositoryCheckpoint {
        GitRepositoryCheckpoint(
            headCommit: head,
            branch: branch,
            isDetachedHead: false,
            indexTree: index,
            operationMode: .normal,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func cleanStatus(branch: String) -> GitStatusSnapshot {
        GitStatusSnapshot(
            repositoryRoot: "/tmp/repo",
            branch: branch,
            isDetachedHead: false,
            paths: [],
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
