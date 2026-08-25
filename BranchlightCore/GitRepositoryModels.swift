import Foundation

public struct GitBranch: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let isCurrent: Bool
    public let upstream: String?

    public var id: String { name }

    public init(name: String, isCurrent: Bool, upstream: String?) {
        self.name = name
        self.isCurrent = isCurrent
        self.upstream = upstream
    }
}

public struct GitCommit: Codable, Hashable, Identifiable, Sendable {
    public let hash: String
    public let shortHash: String
    public let author: String
    public let authoredAt: Date?
    public let subject: String

    public var id: String { hash }

    public init(hash: String, shortHash: String, author: String, authoredAt: Date?, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.authoredAt = authoredAt
        self.subject = subject
    }
}

public struct GitStashEntry: Codable, Hashable, Identifiable, Sendable {
    public let index: Int
    public let reference: String
    public let commitHash: String
    public let message: String

    public var id: String { reference }

    public init(index: Int, reference: String, commitHash: String, message: String) {
        self.index = index
        self.reference = reference
        self.commitHash = commitHash
        self.message = message
    }
}

public struct GitBlameLine: Codable, Hashable, Identifiable, Sendable {
    public let lineNumber: Int
    public let commitHash: String
    public let author: String
    public let authoredAt: Date?
    public let content: String

    public var id: String { "\(lineNumber):\(commitHash)" }

    public init(lineNumber: Int, commitHash: String, author: String, authoredAt: Date?, content: String) {
        self.lineNumber = lineNumber
        self.commitHash = commitHash
        self.author = author
        self.authoredAt = authoredAt
        self.content = content
    }
}

public struct GitWorktree: Codable, Hashable, Identifiable, Sendable {
    public let path: String
    public let head: String
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let lockReason: String?

    public var id: String { path }

    public init(
        path: String,
        head: String,
        branch: String?,
        isBare: Bool,
        isDetached: Bool,
        isLocked: Bool,
        lockReason: String?
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
    }
}

public struct GitCommandResult: Sendable {
    public let stdout: String
    public let stderr: String

    public init(stdout: String, stderr: String) {
        self.stdout = stdout
        self.stderr = stderr
    }
}
