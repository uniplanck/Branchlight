import Foundation

public struct FinderSelectionPlan: Sendable, Equatable {
    public let repositoryRoot: String
    public let paths: [String]
    public let statuses: [GitPathStatus]

    public init(repositoryRoot: String, paths: [String], statuses: [GitPathStatus]) {
        self.repositoryRoot = repositoryRoot
        self.paths = paths
        self.statuses = statuses
    }

    public var canStage: Bool {
        statuses.contains {
            $0.workTreeCode != " " && $0.workTreeCode != "!"
        }
    }

    public var canUnstage: Bool {
        statuses.contains(where: { $0.isStaged })
    }
}

public enum FinderSelectionPlanner {
    public static func plan(
        absolutePaths: [String],
        envelope: StatusCacheEnvelope
    ) -> FinderSelectionPlan? {
        guard let firstPath = absolutePaths.first,
              let snapshot = envelope.snapshot(containing: standardized(firstPath)) else {
            return nil
        }

        let root = snapshot.repositoryRoot
        var paths: [String] = []
        var statuses = Set<GitPathStatus>()

        for inputPath in absolutePaths {
            let absolutePath = standardized(inputPath)
            guard envelope.snapshot(containing: absolutePath)?.repositoryRoot == root else {
                return nil
            }

            let relativePath: String
            if absolutePath == root {
                relativePath = "."
            } else {
                relativePath = String(absolutePath.dropFirst(root.count + 1))
            }
            paths.append(relativePath)

            if relativePath == "." {
                statuses.formUnion(snapshot.paths)
            } else {
                let prefix = relativePath + "/"
                statuses.formUnion(
                    snapshot.paths.filter {
                        $0.path == relativePath || $0.path.hasPrefix(prefix)
                    }
                )
            }
        }

        return FinderSelectionPlan(
            repositoryRoot: root,
            paths: Array(Set(paths)).sorted(),
            statuses: statuses.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        )
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
