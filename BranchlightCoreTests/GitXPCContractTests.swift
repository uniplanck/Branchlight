import BranchlightCore
import Foundation
import XCTest

final class GitXPCContractTests: XCTestCase {
    func testRepositoryIdentityRequestRoundTripsWithStableIdentity() throws {
        let request = GitXPCRepositoryIdentityRequest(
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            repositoryPath: "/tmp/Branchlight Repo"
        )

        let encoded = try GitXPCCodec.encode(request)
        let decoded = try GitXPCCodec.decode(
            GitXPCRepositoryIdentityRequest.self,
            from: encoded
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.protocolVersion, BranchlightGitXPCContract.protocolVersion)
    }

    func testRepositoryIdentityResponsePreservesRequestID() throws {
        let requestID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let identity = GitRepositoryIdentity(
            workingTreeRoot: "/tmp/repo",
            gitDirectory: "/tmp/repo/.git",
            commonGitDirectory: "/tmp/repo/.git"
        )
        let response = GitXPCRepositoryIdentityResponse(
            requestID: requestID,
            identity: identity
        )

        let decoded = try GitXPCCodec.decode(
            GitXPCRepositoryIdentityResponse.self,
            from: GitXPCCodec.encode(response)
        )

        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.identity, identity)
    }

    func testRepositoryIntelligenceResponseRoundTrips() throws {
        let requestID = UUID(uuidString: "12345678-1234-5678-1234-567812345678")!
        let identity = GitRepositoryIdentity(
            workingTreeRoot: "/tmp/repo",
            gitDirectory: "/tmp/repo/.git",
            commonGitDirectory: "/tmp/repo/.git"
        )
        let intelligence = GitRepositoryIntelligence(
            identity: identity,
            branch: "main",
            upstream: "origin/main",
            tracking: GitAheadBehind(ahead: 2, behind: 1),
            isDetachedHead: false,
            operationMode: .normal,
            changedCount: 3,
            stagedCount: 1,
            untrackedCount: 1,
            conflictCount: 0,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let response = GitXPCRepositoryIntelligenceResponse(
            requestID: requestID,
            intelligence: intelligence
        )

        let decoded = try GitXPCCodec.decode(
            GitXPCRepositoryIntelligenceResponse.self,
            from: GitXPCCodec.encode(response)
        )

        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.intelligence, intelligence)
        XCTAssertEqual(decoded.protocolVersion, BranchlightGitXPCContract.protocolVersion)
    }

    func testEveryMutationPayloadRoundTrips() throws {
        let mutations: [GitXPCMutation] = [
            .stage(paths: ["a.txt"]),
            .unstage(paths: ["a.txt"]),
            .applyPatch(patch: "diff --git a/a.txt b/a.txt\n", reverse: false),
            .commit(message: "test", amend: false),
            .fetch,
            .pullFastForwardOnly,
            .push,
            .switchBranch(name: "feature/xpc"),
            .merge(branch: "feature/xpc", confirmationProvided: true),
            .continueMerge,
            .abortMerge,
            .rebase(onto: "main", confirmationProvided: true),
            .continueRebase,
            .abortRebase,
            .skipRebase,
            .createStash(message: "checkpoint", includeUntracked: true),
            .applyStash(reference: "stash@{0}", pop: false),
            .dropStash(reference: "stash@{0}"),
            .addWorktree(path: "/tmp/worktree", branch: "feature/xpc"),
            .addWorktreeWithNewBranch(path: "/tmp/worktree-2", newBranch: "feature/new", startPoint: "HEAD"),
            .removeWorktree(path: "/tmp/worktree"),
            .cherryPick(commitHash: String(repeating: "a", count: 40), confirmationProvided: true),
            .continueCherryPick,
            .abortCherryPick,
            .revert(commitHash: String(repeating: "b", count: 40), confirmationProvided: true),
            .continueRevert,
            .abortRevert
        ]

        for (index, mutation) in mutations.enumerated() {
            let request = GitXPCMutationRequest(
                requestID: UUID(),
                repositoryPath: "/tmp/repo-\(index)",
                mutation: mutation
            )
            let decoded = try GitXPCCodec.decode(
                GitXPCMutationRequest.self,
                from: GitXPCCodec.encode(request)
            )
            XCTAssertEqual(decoded, request, "Mutation payload failed at index \(index)")
        }
    }

    func testMutationResponsePreservesRequestIdentityAndOutput() throws {
        let requestID = UUID()
        let response = GitXPCMutationResponse(
            requestID: requestID,
            output: GitXPCCommandOutput(stdout: "done", stderr: "")
        )
        let decoded = try GitXPCCodec.decode(
            GitXPCMutationResponse.self,
            from: GitXPCCodec.encode(response)
        )
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.requestID, requestID)
    }

    func testProtocolVersionMismatchFailsClosed() {
        XCTAssertThrowsError(
            try GitXPCCodec.validateProtocolVersion(
                BranchlightGitXPCContract.protocolVersion + 1
            )
        ) { error in
            guard case GitXPCContractError.protocolVersionMismatch(let expected, let received) = error else {
                return XCTFail("Expected protocolVersionMismatch, got \(error)")
            }
            XCTAssertEqual(expected, BranchlightGitXPCContract.protocolVersion)
            XCTAssertEqual(received, BranchlightGitXPCContract.protocolVersion + 1)
        }
    }

    func testOversizedMessageIsRejectedBeforeTransport() {
        let request = GitXPCRepositoryIdentityRequest(
            repositoryPath: "/" + String(
                repeating: "a",
                count: BranchlightGitXPCContract.maximumMessageBytes + 32
            )
        )
        XCTAssertThrowsError(try GitXPCCodec.encode(request)) { error in
            guard case GitXPCContractError.messageTooLarge(let byteCount) = error else {
                return XCTFail("Expected messageTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(byteCount, BranchlightGitXPCContract.maximumMessageBytes)
        }
    }
}
