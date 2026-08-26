import BranchlightCore
import Foundation

enum HostFinderRequest: Sendable {
    case intent(FinderIntent)
    case openPath(String)
}

actor HostStatusCache {
    private let cache: SharedStatusCache?
    private let intelligenceService: any GitService

    init(
        cache: SharedStatusCache? = SharedStatusCache(),
        intelligenceService: any GitService = InProcessGitService()
    ) {
        self.cache = cache
        self.intelligenceService = intelligenceService
    }

    func load() -> StatusCacheEnvelope {
        cache?.load() ?? StatusCacheEnvelope()
    }

    func replaceSnapshot(_ snapshot: GitStatusSnapshot) async throws -> StatusCacheEnvelope? {
        guard let cache else { return nil }
        let repositoryURL = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
        let intelligence = try await intelligenceService.repositoryIntelligence(at: repositoryURL)
        return try cache.replaceRepositoryState(snapshot: snapshot, intelligence: intelligence)
    }
}

actor HostFinderRequestCache {
    private let cache: SharedStatusCache?

    init(cache: SharedStatusCache? = SharedStatusCache()) {
        self.cache = cache
    }

    func consumeFinderRequest() -> HostFinderRequest? {
        if let intent = cache?.consumePendingFinderIntent() {
            return .intent(intent)
        }
        if let path = cache?.consumePendingOpenPath() {
            return .openPath(path)
        }
        return nil
    }
}
