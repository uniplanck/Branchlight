import BranchlightCore
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
