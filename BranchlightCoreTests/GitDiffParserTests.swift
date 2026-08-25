import BranchlightCore
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
