import CoreServices
import Foundation

final class RepositoryWatcher: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let queue = DispatchQueue(label: "com.uniplanck.branchlight.repository-watcher", qos: .utility)
    private let handler: Handler
    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?
    private var debounceItem: DispatchWorkItem?

    init(latency: CFTimeInterval = 0.35, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start(path: String) {
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            watcher.scheduleHandler()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        debounceItem?.cancel()
        debounceItem = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleHandler() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [handler] in
            handler()
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}
