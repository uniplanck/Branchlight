import BranchlightCore
import Foundation

enum HostFinderRequest: Sendable {
    case intent(FinderIntent)
    case openPath(String)
}

actor HostStatusCache {
    private let cache: SharedStatusCache?

    init(cache: SharedStatusCache? = SharedStatusCache()) {
        self.cache = cache
    }

    func load() -> StatusCacheEnvelope {
        cache?.load() ?? StatusCacheEnvelope()
    }

    func replaceSnapshot(_ snapshot: GitStatusSnapshot) throws -> StatusCacheEnvelope? {
        try cache?.replaceSnapshot(snapshot)
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
