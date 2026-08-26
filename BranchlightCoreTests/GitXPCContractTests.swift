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
