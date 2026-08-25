import Foundation

public struct GitRepositoryIdentity: Codable, Hashable, Sendable {
    public let workingTreeRoot: String
    public let gitDirectory: String
    public let commonGitDirectory: String

    public var coordinationKey: String { commonGitDirectory }

    public var repositoryURL: URL {
        URL(fileURLWithPath: workingTreeRoot, isDirectory: true)
    }

    public init(workingTreeRoot: String, gitDirectory: String, commonGitDirectory: String) {
        self.workingTreeRoot = workingTreeRoot
        self.gitDirectory = gitDirectory
        self.commonGitDirectory = commonGitDirectory
    }
}

public enum GitRepositoryOperationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case normal
    case merging
    case rebasing
    case cherryPicking
    case reverting
    case bisecting
}

public struct GitRepositoryIntelligence: Codable, Hashable, Sendable {
    public let identity: GitRepositoryIdentity
    public let branch: String
    public let upstream: String?
    public let isDetachedHead: Bool
    public let operationMode: GitRepositoryOperationMode
    public let changedCount: Int
    public let stagedCount: Int
    public let untrackedCount: Int
    public let conflictCount: Int
    public let capturedAt: Date

    public var isClean: Bool { changedCount == 0 }
    public var needsConflictResolution: Bool { conflictCount > 0 }

    public init(
        identity: GitRepositoryIdentity,
        branch: String,
        upstream: String?,
        isDetachedHead: Bool,
        operationMode: GitRepositoryOperationMode,
        changedCount: Int,
        stagedCount: Int,
        untrackedCount: Int,
        conflictCount: Int,
        capturedAt: Date = Date()
    ) {
        self.identity = identity
        self.branch = branch
        self.upstream = upstream
        self.isDetachedHead = isDetachedHead
        self.operationMode = operationMode
        self.changedCount = changedCount
        self.stagedCount = stagedCount
        self.untrackedCount = untrackedCount
        self.conflictCount = conflictCount
        self.capturedAt = capturedAt
    }
}

public enum GitOperationState: String, Codable, Hashable, Sendable {
    case running
    case succeeded
    case failed
}

public struct GitOperationRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let repository: GitRepositoryIdentity
    public let label: String
    public let state: GitOperationState
    public let startedAt: Date
    public let finishedAt: Date?
    public let errorDescription: String?

    public init(
        id: UUID,
        repository: GitRepositoryIdentity,
        label: String,
        state: GitOperationState,
        startedAt: Date,
        finishedAt: Date?,
        errorDescription: String?
    ) {
        self.id = id
        self.repository = repository
        self.label = label
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorDescription = errorDescription
    }
}

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
