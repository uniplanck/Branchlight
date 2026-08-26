import BranchlightCore
import Foundation

private final class XPCReplyBox: @unchecked Sendable {
    private let reply: (Data?, NSError?) -> Void

    init(_ reply: @escaping (Data?, NSError?) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data?, error: NSError?) {
        reply(data, error)
    }
}

private final class BranchlightGitXPCService: NSObject, BranchlightGitXPCProtocol {
    private let gitService: InProcessGitService

    override init() {
        let engine = SystemGitEngine()
        let coordinator = GitOperationCoordinator()
        let registry = GitRepositoryRegistry()
        self.gitService = InProcessGitService(
            engine: engine,
            coordinator: coordinator,
            registry: registry
        )
        super.init()
    }

    func probe(withReply reply: @escaping (Int) -> Void) {
        reply(BranchlightGitXPCContract.protocolVersion)
    }

    func repositoryIdentity(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let gitService = gitService

        Task {
            do {
                let request = try GitXPCCodec.decode(
                    GitXPCRepositoryIdentityRequest.self,
                    from: requestData
                )
                try GitXPCCodec.validateProtocolVersion(request.protocolVersion)
                let repositoryURL = try Self.validatedRepositoryURL(request.repositoryPath)
                let identity = try await gitService.repositoryIdentity(at: repositoryURL)
                let response = GitXPCRepositoryIdentityResponse(
                    requestID: request.requestID,
                    identity: identity
                )
                replyBox.send(try GitXPCCodec.encode(response), error: nil)
            } catch {
                replyBox.send(nil, error: error as NSError)
            }
        }
    }

    func repositoryIntelligence(
        _ requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let gitService = gitService

        Task {
            do {
                let request = try GitXPCCodec.decode(
                    GitXPCRepositoryIntelligenceRequest.self,
                    from: requestData
                )
                try GitXPCCodec.validateProtocolVersion(request.protocolVersion)
                let repositoryURL = try Self.validatedRepositoryURL(request.repositoryPath)
                let intelligence = try await gitService.repositoryIntelligence(at: repositoryURL)
                let response = GitXPCRepositoryIntelligenceResponse(
                    requestID: request.requestID,
                    intelligence: intelligence
                )
                replyBox.send(try GitXPCCodec.encode(response), error: nil)
            } catch {
                replyBox.send(nil, error: error as NSError)
            }
        }
    }

    private static func validatedRepositoryURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw GitEngineError.invalidInput(
                "XPC repository requests require an absolute local path."
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

private final class BranchlightGitXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = BranchlightGitXPCService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: BranchlightGitXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

private let listenerDelegate = BranchlightGitXPCListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = listenerDelegate
listener.resume()
