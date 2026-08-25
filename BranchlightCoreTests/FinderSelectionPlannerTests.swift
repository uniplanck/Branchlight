import BranchlightCore
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
            paths: [
                GitPathStatus(path: "Other.swift", indexCode: " ", workTreeCode: "M", kind: .modified)
            ]
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
        return StatusCacheEnvelope(
            revision: 1,
            monitoredRoots: [repositoryRoot],
            snapshots: [repositoryRoot: snapshot]
        )
    }
}
