import CoreFoundation
import Foundation

public enum FinderIntentAction: String, Codable, Sendable {
    case showChanges
    case stage
    case unstage
    case openRepository
}

public struct FinderIntent: Codable, Sendable, Equatable {
    public let action: FinderIntentAction
    public let repositoryRoot: String
    public let paths: [String]
    public let requestedAt: Date

    public init(
        action: FinderIntentAction,
        repositoryRoot: String,
        paths: [String] = [],
        requestedAt: Date = Date()
    ) {
        self.action = action
        self.repositoryRoot = repositoryRoot
        self.paths = paths
        self.requestedAt = requestedAt
    }
}

public struct StatusCacheEnvelope: Codable, Sendable {
    public var revision: Int
    public var monitoredRoots: [String]
    public var snapshots: [String: GitStatusSnapshot]
    public var repositoryIntelligence: [String: GitRepositoryIntelligence]?

    public init(
        revision: Int = 0,
        monitoredRoots: [String] = [],
        snapshots: [String: GitStatusSnapshot] = [:],
        repositoryIntelligence: [String: GitRepositoryIntelligence]? = nil
    ) {
        self.revision = revision
        self.monitoredRoots = monitoredRoots
        self.snapshots = snapshots
        self.repositoryIntelligence = repositoryIntelligence
    }

    public func snapshot(containing absolutePath: String) -> GitStatusSnapshot? {
        snapshots.values
            .filter { absolutePath == $0.repositoryRoot || absolutePath.hasPrefix($0.repositoryRoot + "/") }
            .max { $0.repositoryRoot.count < $1.repositoryRoot.count }
    }

    public func intelligence(forRepositoryRoot repositoryRoot: String) -> GitRepositoryIntelligence? {
        repositoryIntelligence?[repositoryRoot]
    }

    public func statusKind(forAbsolutePath absolutePath: String) -> GitStatusKind {
        guard let snapshot = snapshot(containing: absolutePath) else { return .clean }
        let root = snapshot.repositoryRoot
        let relativePath: String
        if absolutePath == root {
            relativePath = ""
        } else {
            relativePath = String(absolutePath.dropFirst(root.count + 1))
        }

        if relativePath.isEmpty {
            return GitStatusClassifier.aggregate(snapshot.paths.map(\.kind))
        }

        if let exact = snapshot.paths.first(where: { $0.path == relativePath }) {
            return exact.kind
        }

        let prefix = relativePath.hasSuffix("/") ? relativePath : relativePath + "/"
        let descendants = snapshot.paths.lazy
            .filter { $0.path.hasPrefix(prefix) }
            .map(\.kind)
        return GitStatusClassifier.aggregate(descendants)
    }
}

public enum FinderIntegrationCompatibility {
    public static func warning(
        for repositoryURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let repositoryPath = repositoryURL.standardizedFileURL.path
        let home = homeDirectoryURL.standardizedFileURL
        let providerRoots = [
            home.appendingPathComponent("Library/CloudStorage", isDirectory: true),
            home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        ]

        guard providerRoots.contains(where: { root in
            let rootPath = root.standardizedFileURL.path
            return repositoryPath == rootPath || repositoryPath.hasPrefix(rootPath + "/")
        }) else {
            return nil
        }

        return "This repository appears to be inside a File Provider-managed folder. macOS may give that provider priority over Finder Sync, so Branchlight badges or menus can be unavailable even when Git status in the app works."
    }
}

public enum SharedStatusNotifications {
    public static let cacheChanged = CFNotificationName("com.uniplanck.branchlight.cache.changed" as CFString)

    public static func postCacheChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            cacheChanged,
            nil,
            nil,
            true
        )
    }
}

public final class SharedStatusCache: @unchecked Sendable {
    public static let suiteName = "group.com.uniplanck.branchlight"
    private static let envelopeKey = "statusCacheEnvelopeV1"
    private static let pendingOpenPathKey = "pendingFinderOpenPathV1"
    private static let pendingFinderIntentKey = "pendingFinderIntentV1"

    private static let envelopeFilename = "status-cache-envelope-v1.json"
    private static let pendingOpenPathFilename = "pending-finder-open-path-v1.json"
    private static let pendingFinderIntentFilename = "pending-finder-intent-v1.json"
    private static let retainedCorruptBackupCount = 3

    private let storageDirectoryURL: URL
    private let legacyPreferencesURL: URL?
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public convenience init?(suiteName: String = SharedStatusCache.suiteName) {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else {
            return nil
        }

        let storageDirectoryURL = containerURL
            .appendingPathComponent("Library/Application Support/Branchlight", isDirectory: true)
        let legacyPreferencesURL = containerURL
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(suiteName).plist", isDirectory: false)

        self.init(
            storageDirectoryURL: storageDirectoryURL,
            legacyPreferencesURL: legacyPreferencesURL,
            fileManager: fileManager
        )
    }

    public init(
        storageDirectoryURL: URL,
        legacyPreferencesURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.storageDirectoryURL = storageDirectoryURL.standardizedFileURL
        self.legacyPreferencesURL = legacyPreferencesURL?.standardizedFileURL
        self.fileManager = fileManager
    }

    public func load() -> StatusCacheEnvelope {
        withLock {
            if let envelope: StatusCacheEnvelope = readJSONOrQuarantine(from: envelopeURL) {
                return envelope
            }

            guard let legacyData = legacyData(forKey: Self.envelopeKey),
                  let envelope = try? decoder.decode(StatusCacheEnvelope.self, from: legacyData) else {
                return StatusCacheEnvelope()
            }

            try? writeJSON(envelope, to: envelopeURL)
            return envelope
        }
    }

    public func save(_ envelope: StatusCacheEnvelope) throws {
        try withLock {
            try writeJSON(envelope, to: envelopeURL)
        }
        SharedStatusNotifications.postCacheChanged()
    }

    public func setPendingOpenPath(_ path: String) {
        try? withLock {
            try writeJSON(path, to: pendingOpenPathURL)
        }
    }

    public func consumePendingOpenPath() -> String? {
        withLock {
            if let path: String = readJSONOrQuarantine(from: pendingOpenPathURL) {
                try? fileManager.removeItem(at: pendingOpenPathURL)
                return path
            }

            guard !legacyValueWasConsumed(forKey: Self.pendingOpenPathKey),
                  let path = legacyValue(forKey: Self.pendingOpenPathKey) as? String else {
                return nil
            }
            markLegacyValueConsumed(forKey: Self.pendingOpenPathKey)
            return path
        }
    }

    public func setPendingFinderIntent(_ intent: FinderIntent) throws {
        try withLock {
            try writeJSON(intent, to: pendingFinderIntentURL)
        }
    }

    public func consumePendingFinderIntent() -> FinderIntent? {
        withLock {
            if let intent: FinderIntent = readJSONOrQuarantine(from: pendingFinderIntentURL) {
                try? fileManager.removeItem(at: pendingFinderIntentURL)
                return intent
            }

            guard !legacyValueWasConsumed(forKey: Self.pendingFinderIntentKey),
                  let data = legacyData(forKey: Self.pendingFinderIntentKey),
                  let intent = try? decoder.decode(FinderIntent.self, from: data) else {
                return nil
            }
            markLegacyValueConsumed(forKey: Self.pendingFinderIntentKey)
            return intent
        }
    }

    public func replaceSnapshot(_ snapshot: GitStatusSnapshot) throws -> StatusCacheEnvelope {
        let envelope = try withLock { () throws -> StatusCacheEnvelope in
            var envelope = readEnvelopeUnlocked()
            envelope.revision += 1
            envelope.snapshots[snapshot.repositoryRoot] = snapshot
            if !envelope.monitoredRoots.contains(snapshot.repositoryRoot) {
                envelope.monitoredRoots.append(snapshot.repositoryRoot)
                envelope.monitoredRoots.sort()
            }
            try writeJSON(envelope, to: envelopeURL)
            return envelope
        }
        SharedStatusNotifications.postCacheChanged()
        return envelope
    }

    public func replaceRepositoryState(
        snapshot: GitStatusSnapshot,
        intelligence: GitRepositoryIntelligence
    ) throws -> StatusCacheEnvelope {
        let envelope = try withLock { () throws -> StatusCacheEnvelope in
            var envelope = readEnvelopeUnlocked()
            envelope.revision += 1
            envelope.snapshots[snapshot.repositoryRoot] = snapshot
            var intelligenceByRoot = envelope.repositoryIntelligence ?? [:]
            intelligenceByRoot[snapshot.repositoryRoot] = intelligence
            envelope.repositoryIntelligence = intelligenceByRoot
            if !envelope.monitoredRoots.contains(snapshot.repositoryRoot) {
                envelope.monitoredRoots.append(snapshot.repositoryRoot)
                envelope.monitoredRoots.sort()
            }
            try writeJSON(envelope, to: envelopeURL)
            return envelope
        }
        SharedStatusNotifications.postCacheChanged()
        return envelope
    }

    public func setMonitoredRoots(_ roots: [String]) throws -> StatusCacheEnvelope {
        let envelope = try withLock { () throws -> StatusCacheEnvelope in
            var envelope = readEnvelopeUnlocked()
            envelope.revision += 1
            envelope.monitoredRoots = Array(Set(roots)).sorted()
            try writeJSON(envelope, to: envelopeURL)
            return envelope
        }
        SharedStatusNotifications.postCacheChanged()
        return envelope
    }

    private var envelopeURL: URL {
        storageDirectoryURL.appendingPathComponent(Self.envelopeFilename, isDirectory: false)
    }

    private var pendingOpenPathURL: URL {
        storageDirectoryURL.appendingPathComponent(Self.pendingOpenPathFilename, isDirectory: false)
    }

    private var pendingFinderIntentURL: URL {
        storageDirectoryURL.appendingPathComponent(Self.pendingFinderIntentFilename, isDirectory: false)
    }

    private func readEnvelopeUnlocked() -> StatusCacheEnvelope {
        if let envelope: StatusCacheEnvelope = readJSONOrQuarantine(from: envelopeURL) {
            return envelope
        }
        if let legacyData = legacyData(forKey: Self.envelopeKey),
           let envelope = try? decoder.decode(StatusCacheEnvelope.self, from: legacyData) {
            return envelope
        }
        return StatusCacheEnvelope()
    }

    private func readJSONOrQuarantine<T: Decodable>(from url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let decoded = try? decoder.decode(T.self, from: data) {
            return decoded
        }

        quarantineCorruptFile(at: url)
        return nil
    }

    private func quarantineCorruptFile(at url: URL) {
        let prefix = url.lastPathComponent + ".corrupt-"
        let quarantineURL = storageDirectoryURL.appendingPathComponent(
            prefix + UUID().uuidString,
            isDirectory: false
        )
        guard (try? fileManager.moveItem(at: url, to: quarantineURL)) != nil else { return }
        pruneCorruptBackups(prefix: prefix)
    }

    private func pruneCorruptBackups(prefix: String) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let backups = urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }

        for backup in backups.dropFirst(Self.retainedCorruptBackupCount) {
            try? fileManager.removeItem(at: backup.0)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func legacyValue(forKey key: String) -> Any? {
        guard let legacyPreferencesURL,
              let data = try? Data(contentsOf: legacyPreferencesURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary[key]
    }

    private func legacyData(forKey key: String) -> Data? {
        legacyValue(forKey: key) as? Data
    }

    private func legacyConsumedMarkerURL(forKey key: String) -> URL {
        storageDirectoryURL.appendingPathComponent("legacy-\(key)-consumed", isDirectory: false)
    }

    private func legacyValueWasConsumed(forKey key: String) -> Bool {
        fileManager.fileExists(atPath: legacyConsumedMarkerURL(forKey: key).path)
    }

    private func markLegacyValueConsumed(forKey key: String) {
        let markerURL = legacyConsumedMarkerURL(forKey: key)
        try? fileManager.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )
        _ = fileManager.createFile(atPath: markerURL.path, contents: Data())
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
