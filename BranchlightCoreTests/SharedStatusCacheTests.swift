import BranchlightCore
import Foundation
import XCTest

final class SharedStatusCacheTests: XCTestCase {
    private func makeCache() throws -> (SharedStatusCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightSharedStatusCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SharedStatusCache(storageDirectoryURL: directory), directory)
    }

    func testPersistsSnapshotAndMonitoredRoot() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = GitStatusSnapshot(
            repositoryRoot: "/tmp/example-repo",
            branch: "main",
            isDetachedHead: false,
            paths: [
                GitPathStatus(
                    path: "Sources/File.swift",
                    indexCode: " ",
                    workTreeCode: "M",
                    kind: .modified
                )
            ]
        )

        _ = try cache.replaceSnapshot(snapshot)
        let reloaded = cache.load()

        XCTAssertEqual(reloaded.monitoredRoots, ["/tmp/example-repo"])
        XCTAssertEqual(reloaded.snapshots["/tmp/example-repo"]?.branch, "main")
        XCTAssertEqual(reloaded.statusKind(forAbsolutePath: "/tmp/example-repo/Sources"), .modified)
    }

    func testPendingFinderPathIsConsumedOnce() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        cache.setPendingOpenPath("/tmp/example-repo/File.swift")

        XCTAssertEqual(cache.consumePendingOpenPath(), "/tmp/example-repo/File.swift")
        XCTAssertNil(cache.consumePendingOpenPath())
    }

    func testFinderIntegrationCompatibilityWarnsForCloudStorage() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let cloudRepository = URL(fileURLWithPath: "/Users/tester/Library/CloudStorage/Dropbox/project", isDirectory: true)
        let localRepository = URL(fileURLWithPath: "/Users/tester/Projects/project", isDirectory: true)

        XCTAssertNotNil(
            FinderIntegrationCompatibility.warning(for: cloudRepository, homeDirectoryURL: home)
        )
        XCTAssertNil(
            FinderIntegrationCompatibility.warning(for: localRepository, homeDirectoryURL: home)
        )
    }

    func testPendingFinderIntentIsConsumedOnce() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let intent = FinderIntent(
            action: .stage,
            repositoryRoot: "/tmp/example-repo",
            paths: ["Sources/File.swift"],
            requestedAt: Date(timeIntervalSince1970: 123)
        )
        try cache.setPendingFinderIntent(intent)

        XCTAssertEqual(cache.consumePendingFinderIntent(), intent)
        XCTAssertNil(cache.consumePendingFinderIntent())
    }

    func testMigratesLegacyEnvelopeWithoutUserDefaultsAccess() throws {
        let (cacheDirectory, legacyPreferencesURL) = try makeMigrationFixture()
        defer { try? FileManager.default.removeItem(at: cacheDirectory.deletingLastPathComponent()) }

        let snapshot = GitStatusSnapshot(
            repositoryRoot: "/tmp/legacy-repo",
            branch: "legacy",
            isDetachedHead: false,
            paths: []
        )
        let envelope = StatusCacheEnvelope(
            revision: 41,
            monitoredRoots: ["/tmp/legacy-repo"],
            snapshots: ["/tmp/legacy-repo": snapshot]
        )
        let legacyPlist: [String: Any] = [
            "statusCacheEnvelopeV1": try JSONEncoder().encode(envelope)
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: legacyPlist,
            format: .binary,
            options: 0
        )
        try plistData.write(to: legacyPreferencesURL, options: .atomic)

        let cache = SharedStatusCache(
            storageDirectoryURL: cacheDirectory,
            legacyPreferencesURL: legacyPreferencesURL
        )
        let migrated = cache.load()
        XCTAssertEqual(migrated.revision, 41)
        XCTAssertEqual(migrated.monitoredRoots, ["/tmp/legacy-repo"])

        try FileManager.default.removeItem(at: legacyPreferencesURL)
        let reloaded = cache.load()
        XCTAssertEqual(reloaded.revision, 41)
        XCTAssertEqual(reloaded.monitoredRoots, ["/tmp/legacy-repo"])
    }

    private func makeMigrationFixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchlightLegacyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDirectory = root.appendingPathComponent("Shared", isDirectory: true)
        let preferencesDirectory = root.appendingPathComponent("Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        let preferencesURL = preferencesDirectory.appendingPathComponent("legacy.plist")
        return (cacheDirectory, preferencesURL)
    }
}
