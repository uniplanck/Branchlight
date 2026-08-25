import Foundation

public enum GitStatusKind: String, Codable, CaseIterable, Sendable {
    case clean
    case staged
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case ignored
    case conflicted
}

public struct GitPathStatus: Codable, Hashable, Sendable {
    public let path: String
    public let indexCode: String
    public let workTreeCode: String
    public let kind: GitStatusKind

    public init(path: String, indexCode: String, workTreeCode: String, kind: GitStatusKind) {
        self.path = path
        self.indexCode = indexCode
        self.workTreeCode = workTreeCode
        self.kind = kind
    }

    public var isStaged: Bool {
        indexCode != " " && indexCode != "?" && indexCode != "!"
    }
}

public struct GitStatusSnapshot: Codable, Hashable, Sendable {
    public let repositoryRoot: String
    public let branch: String
    public let isDetachedHead: Bool
    public let paths: [GitPathStatus]
    public let capturedAt: Date

    public init(
        repositoryRoot: String,
        branch: String,
        isDetachedHead: Bool,
        paths: [GitPathStatus],
        capturedAt: Date = Date()
    ) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.isDetachedHead = isDetachedHead
        self.paths = paths
        self.capturedAt = capturedAt
    }

    public var isClean: Bool { paths.isEmpty }

    public var summary: String {
        guard !paths.isEmpty else { return "Clean" }
        let conflicts = paths.count { $0.kind == .conflicted }
        let staged = paths.count { $0.isStaged }
        let untracked = paths.count { $0.kind == .untracked }
        var parts: [String] = ["\(paths.count) changed"]
        if staged > 0 { parts.append("\(staged) staged") }
        if untracked > 0 { parts.append("\(untracked) untracked") }
        if conflicts > 0 { parts.append("\(conflicts) conflicts") }
        return parts.joined(separator: " · ")
    }
}

public enum GitStatusClassifier {
    private static let conflictPairs: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    public static func classify(index: String, workTree: String) -> GitStatusKind {
        let pair = index + workTree
        if conflictPairs.contains(pair) { return .conflicted }
        if pair == "??" { return .untracked }
        if pair == "!!" { return .ignored }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "A" || workTree == "A" { return .added }
        if workTree == "M" || workTree == "T" { return .modified }
        if index != " " { return .staged }
        return .clean
    }

    public static func priority(_ kind: GitStatusKind) -> Int {
        switch kind {
        case .conflicted: return 900
        case .modified: return 800
        case .deleted: return 750
        case .renamed: return 700
        case .added: return 650
        case .untracked: return 600
        case .staged: return 500
        case .ignored: return 100
        case .clean: return 0
        }
    }

    public static func aggregate(_ kinds: some Sequence<GitStatusKind>) -> GitStatusKind {
        kinds.max(by: { priority($0) < priority($1) }) ?? .clean
    }
}
