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

public struct GitAheadBehind: Codable, Hashable, Sendable {
    public let ahead: Int
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = max(0, ahead)
        self.behind = max(0, behind)
    }

    public var isSynchronized: Bool { ahead == 0 && behind == 0 }
    public var isDiverged: Bool { ahead > 0 && behind > 0 }

    public var summary: String {
        "↑\(ahead) ↓\(behind)"
    }
}

public struct GitRepositoryIntelligence: Codable, Hashable, Sendable {
    public let identity: GitRepositoryIdentity
    public let branch: String
    public let upstream: String?
    public let tracking: GitAheadBehind?
    public let isDetachedHead: Bool
    public let operationMode: GitRepositoryOperationMode
    public let changedCount: Int
    public let stagedCount: Int
    public let untrackedCount: Int
    public let conflictCount: Int
    public let capturedAt: Date

    public var isClean: Bool { changedCount == 0 }
    public var needsConflictResolution: Bool { conflictCount > 0 }
    public var aheadCount: Int? { tracking?.ahead }
    public var behindCount: Int? { tracking?.behind }
    public var hasUpstreamDivergence: Bool { tracking?.isDiverged == true }

    public init(
        identity: GitRepositoryIdentity,
        branch: String,
        upstream: String?,
        tracking: GitAheadBehind? = nil,
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
        self.tracking = tracking
        self.isDetachedHead = isDetachedHead
        self.operationMode = operationMode
        self.changedCount = changedCount
        self.stagedCount = stagedCount
        self.untrackedCount = untrackedCount
        self.conflictCount = conflictCount
        self.capturedAt = capturedAt
    }
}

public enum GitMutationRisk: Int, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case safe = 0
    case caution = 1
    case destructive = 2

    public static func < (lhs: GitMutationRisk, rhs: GitMutationRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum GitMutationIntent: String, Codable, CaseIterable, Hashable, Sendable {
    case stage
    case unstage
    case commit
    case fetch
    case pull
    case push
    case switchBranch
    case stashCreate
    case stashApply
    case stashDrop
    case worktreeAdd
    case worktreeRemove
    case merge
    case rebase
    case cherryPick
    case revert
    case resetHard
}

public enum GitSafetySignal: String, Codable, CaseIterable, Hashable, Sendable {
    case dirtyWorkingTree
    case untrackedFiles
    case conflicts
    case operationInProgress
    case detachedHead
    case noUpstream
    case upstreamBehind
    case upstreamDiverged
}

public struct GitPreflightReport: Codable, Hashable, Sendable {
    public let intent: GitMutationIntent
    public let risk: GitMutationRisk
    public let signals: Set<GitSafetySignal>
    public let blockingReasons: [String]
    public let warnings: [String]

    public init(
        intent: GitMutationIntent,
        risk: GitMutationRisk,
        signals: Set<GitSafetySignal>,
        blockingReasons: [String],
        warnings: [String]
    ) {
        self.intent = intent
        self.risk = risk
        self.signals = signals
        self.blockingReasons = blockingReasons
        self.warnings = warnings
    }

    public var canProceed: Bool { blockingReasons.isEmpty }
    public var requiresConfirmation: Bool {
        risk != .safe || !warnings.isEmpty
    }
}

public enum GitSafetyPreflight {
    public static func evaluate(
        intent: GitMutationIntent,
        intelligence: GitRepositoryIntelligence
    ) -> GitPreflightReport {
        let signals = safetySignals(for: intelligence)
        var risk = baseRisk(for: intent)
        var blockers: [String] = []
        var warnings: [String] = []

        if signals.contains(.operationInProgress), blocksDuringOperation(intent) {
            blockers.append("Finish or abort the current Git operation before starting this action.")
        }
        if signals.contains(.conflicts), blocksWithConflicts(intent) {
            blockers.append("Resolve the current conflicts before starting this action.")
        }

        if signals.contains(.dirtyWorkingTree), warnsWhenDirty(intent) {
            warnings.append("The working tree contains uncommitted changes.")
            risk = max(risk, .caution)
        }
        if signals.contains(.untrackedFiles), warnsWhenDirty(intent) {
            warnings.append("Untracked files are present and may affect the operation.")
            risk = max(risk, .caution)
        }
        if signals.contains(.upstreamDiverged), intent == .pull || intent == .push {
            warnings.append("Local and upstream history have diverged.")
            risk = max(risk, .caution)
        } else if signals.contains(.upstreamBehind), intent == .push {
            warnings.append("The upstream branch contains commits that are not local.")
            risk = max(risk, .caution)
        }
        if signals.contains(.noUpstream), intent == .pull || intent == .push {
            warnings.append("The current branch has no configured upstream.")
            risk = max(risk, .caution)
        }
        if signals.contains(.detachedHead), requiresBranchContext(intent) {
            warnings.append("HEAD is detached; branch-oriented behavior may be surprising.")
            risk = max(risk, .caution)
        }
        if !blockers.isEmpty {
            risk = max(risk, .caution)
        }

        return GitPreflightReport(
            intent: intent,
            risk: risk,
            signals: signals,
            blockingReasons: blockers,
            warnings: warnings
        )
    }

    private static func safetySignals(for intelligence: GitRepositoryIntelligence) -> Set<GitSafetySignal> {
        var signals: Set<GitSafetySignal> = []
        if intelligence.changedCount > 0 { signals.insert(.dirtyWorkingTree) }
        if intelligence.untrackedCount > 0 { signals.insert(.untrackedFiles) }
        if intelligence.conflictCount > 0 { signals.insert(.conflicts) }
        if intelligence.operationMode != .normal { signals.insert(.operationInProgress) }
        if intelligence.isDetachedHead { signals.insert(.detachedHead) }
        if intelligence.upstream == nil { signals.insert(.noUpstream) }
        if let tracking = intelligence.tracking {
            if tracking.behind > 0 { signals.insert(.upstreamBehind) }
            if tracking.isDiverged { signals.insert(.upstreamDiverged) }
        }
        return signals
    }

    private static func baseRisk(for intent: GitMutationIntent) -> GitMutationRisk {
        switch intent {
        case .fetch, .stage, .unstage, .commit, .push, .stashCreate, .worktreeAdd:
            return .safe
        case .pull, .switchBranch, .stashApply, .merge, .rebase, .cherryPick, .revert:
            return .caution
        case .stashDrop, .worktreeRemove, .resetHard:
            return .destructive
        }
    }

    private static func blocksDuringOperation(_ intent: GitMutationIntent) -> Bool {
        switch intent {
        case .fetch, .stage, .unstage, .commit, .push, .stashCreate:
            return false
        case .pull, .switchBranch, .stashApply, .stashDrop, .worktreeAdd, .worktreeRemove,
             .merge, .rebase, .cherryPick, .revert, .resetHard:
            return true
        }
    }

    private static func blocksWithConflicts(_ intent: GitMutationIntent) -> Bool {
        switch intent {
        case .fetch, .stage, .unstage, .commit, .push:
            return false
        case .pull, .switchBranch, .stashCreate, .stashApply, .stashDrop, .worktreeAdd, .worktreeRemove,
             .merge, .rebase, .cherryPick, .revert, .resetHard:
            return true
        }
    }

    private static func warnsWhenDirty(_ intent: GitMutationIntent) -> Bool {
        switch intent {
        case .pull, .switchBranch, .stashApply, .merge, .rebase, .cherryPick, .revert, .resetHard:
            return true
        case .stage, .unstage, .commit, .fetch, .push, .stashCreate, .stashDrop, .worktreeAdd, .worktreeRemove:
            return false
        }
    }

    private static func requiresBranchContext(_ intent: GitMutationIntent) -> Bool {
        switch intent {
        case .pull, .push, .switchBranch, .merge, .rebase:
            return true
        case .stage, .unstage, .commit, .fetch, .stashCreate, .stashApply, .stashDrop,
             .worktreeAdd, .worktreeRemove, .cherryPick, .revert, .resetHard:
            return false
        }
    }
}

public struct GitOperationDescriptor: Codable, Hashable, Sendable {
    public let intent: GitMutationIntent
    public let affectedPaths: [String]
    public let reference: String?
    public let target: String?
    public let parameters: [String: String]

    public init(
        intent: GitMutationIntent,
        affectedPaths: [String] = [],
        reference: String? = nil,
        target: String? = nil,
        parameters: [String: String] = [:]
    ) {
        self.intent = intent
        self.affectedPaths = affectedPaths
        self.reference = reference
        self.target = target
        self.parameters = parameters
    }
}

public struct GitRepositoryCheckpoint: Codable, Hashable, Sendable {
    public let headCommit: String?
    public let branch: String?
    public let isDetachedHead: Bool
    public let indexTree: String?
    public let operationMode: GitRepositoryOperationMode
    public let capturedAt: Date

    public init(
        headCommit: String?,
        branch: String?,
        isDetachedHead: Bool,
        indexTree: String?,
        operationMode: GitRepositoryOperationMode,
        capturedAt: Date = Date()
    ) {
        self.headCommit = headCommit
        self.branch = branch
        self.isDetachedHead = isDetachedHead
        self.indexTree = indexTree
        self.operationMode = operationMode
        self.capturedAt = capturedAt
    }
}

public enum GitOperationState: String, Codable, Hashable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

public struct GitOperationRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let repository: GitRepositoryIdentity
    public let label: String
    public let descriptor: GitOperationDescriptor?
    public let preCheckpoint: GitRepositoryCheckpoint?
    public let postCheckpoint: GitRepositoryCheckpoint?
    public let state: GitOperationState
    public let startedAt: Date
    public let finishedAt: Date?
    public let errorDescription: String?

    public init(
        id: UUID,
        repository: GitRepositoryIdentity,
        label: String,
        descriptor: GitOperationDescriptor? = nil,
        preCheckpoint: GitRepositoryCheckpoint? = nil,
        postCheckpoint: GitRepositoryCheckpoint? = nil,
        state: GitOperationState,
        startedAt: Date,
        finishedAt: Date?,
        errorDescription: String?
    ) {
        self.id = id
        self.repository = repository
        self.label = label
        self.descriptor = descriptor
        self.preCheckpoint = preCheckpoint
        self.postCheckpoint = postCheckpoint
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorDescription = errorDescription
    }
}

public enum GitRecoveryAvailability: String, Codable, CaseIterable, Hashable, Sendable {
    case unavailable
    case validationRequired
}

public struct GitRecoveryPlan: Codable, Hashable, Sendable {
    public let sourceOperationID: UUID
    public let availability: GitRecoveryAvailability
    public let inverseIntent: GitMutationIntent?
    public let affectedPaths: [String]
    public let target: String?
    public let expectedCurrentHead: String?
    public let expectedCurrentIndexTree: String?
    public let reason: String

    public init(
        sourceOperationID: UUID,
        availability: GitRecoveryAvailability,
        inverseIntent: GitMutationIntent?,
        affectedPaths: [String] = [],
        target: String? = nil,
        expectedCurrentHead: String? = nil,
        expectedCurrentIndexTree: String? = nil,
        reason: String
    ) {
        self.sourceOperationID = sourceOperationID
        self.availability = availability
        self.inverseIntent = inverseIntent
        self.affectedPaths = affectedPaths
        self.target = target
        self.expectedCurrentHead = expectedCurrentHead
        self.expectedCurrentIndexTree = expectedCurrentIndexTree
        self.reason = reason
    }

    public var isRecoverableCandidate: Bool { availability == .validationRequired }
}

public enum GitRecoveryPlanner {
    public static func plan(for record: GitOperationRecord) -> GitRecoveryPlan {
        guard record.state == .succeeded else {
            return unavailable(record, "Only successfully completed operations can produce a recovery candidate.")
        }
        guard let descriptor = record.descriptor else {
            return unavailable(record, "This journal entry predates structured recovery metadata.")
        }

        switch descriptor.intent {
        case .stage:
            guard descriptor.target != "patch", !descriptor.affectedPaths.isEmpty else {
                return unavailable(record, "Patch-level staging requires a captured patch or index checkpoint before reversal.")
            }
            guard let preIndex = record.preCheckpoint?.indexTree,
                  let postIndex = record.postCheckpoint?.indexTree,
                  preIndex != postIndex else {
                return unavailable(record, "A distinct pre/post index checkpoint is required before unstaging can be proposed.")
            }
            return GitRecoveryPlan(
                sourceOperationID: record.id,
                availability: .validationRequired,
                inverseIntent: .unstage,
                affectedPaths: descriptor.affectedPaths,
                expectedCurrentHead: record.postCheckpoint?.headCommit,
                expectedCurrentIndexTree: postIndex,
                reason: "Validate HEAD and the current index tree against the post-operation checkpoint before restoring staged paths."
            )
        case .unstage:
            guard descriptor.target != "patch", !descriptor.affectedPaths.isEmpty else {
                return unavailable(record, "Patch-level unstaging requires the previous index contents to be checkpointed.")
            }
            guard let preIndex = record.preCheckpoint?.indexTree,
                  let postIndex = record.postCheckpoint?.indexTree,
                  preIndex != postIndex else {
                return unavailable(record, "A distinct pre/post index checkpoint is required before restaging can be proposed.")
            }
            return GitRecoveryPlan(
                sourceOperationID: record.id,
                availability: .validationRequired,
                inverseIntent: .stage,
                affectedPaths: descriptor.affectedPaths,
                expectedCurrentHead: record.postCheckpoint?.headCommit,
                expectedCurrentIndexTree: postIndex,
                reason: "Restaging whole paths can differ from a prior partial index, so checkpoint validation remains mandatory."
            )
        case .switchBranch:
            guard let previousBranch = record.preCheckpoint?.branch,
                  record.preCheckpoint?.isDetachedHead == false,
                  !previousBranch.isEmpty else {
                return unavailable(record, "The previous attached branch is not available in the pre-operation checkpoint.")
            }
            return GitRecoveryPlan(
                sourceOperationID: record.id,
                availability: .validationRequired,
                inverseIntent: .switchBranch,
                target: previousBranch,
                expectedCurrentHead: record.postCheckpoint?.headCommit,
                expectedCurrentIndexTree: record.postCheckpoint?.indexTree,
                reason: "Return to the previous branch only if HEAD and index still match the post-switch checkpoint."
            )
        case .commit:
            guard let createdCommit = record.postCheckpoint?.headCommit,
                  let previousHead = record.preCheckpoint?.headCommit,
                  createdCommit != previousHead else {
                return unavailable(record, "The created commit cannot be distinguished from the pre-operation HEAD.")
            }
            return GitRecoveryPlan(
                sourceOperationID: record.id,
                availability: .validationRequired,
                inverseIntent: .revert,
                target: createdCommit,
                expectedCurrentHead: createdCommit,
                expectedCurrentIndexTree: record.postCheckpoint?.indexTree,
                reason: "Prefer a new revert commit over rewriting history, and only after validating the post-commit checkpoint."
            )
        case .worktreeAdd:
            guard let target = descriptor.target, !target.isEmpty else {
                return unavailable(record, "The created worktree path was not recorded.")
            }
            return GitRecoveryPlan(
                sourceOperationID: record.id,
                availability: .validationRequired,
                inverseIntent: .worktreeRemove,
                target: target,
                expectedCurrentHead: record.postCheckpoint?.headCommit,
                reason: "Verify the worktree is still registered, clean, unlocked, and unchanged before removal."
            )
        case .pull:
            return unavailable(record, "A pull can change both HEAD and the working tree; rollback remains disabled until a full restore executor exists.")
        case .push:
            return unavailable(record, "Remote history must never be rewritten automatically as an undo operation.")
        case .stashCreate:
            return unavailable(record, "The created stash reference must be captured before a drop recovery can be proposed.")
        case .stashApply:
            return unavailable(record, "Applying or popping a stash mutates the working tree and requires a durable working-tree checkpoint.")
        case .stashDrop:
            return unavailable(record, "Dropping a stash is destructive and has no guaranteed local inverse.")
        case .worktreeRemove:
            return unavailable(record, "Removed worktree contents are not guaranteed to be reconstructable from journal metadata alone.")
        case .fetch:
            return unavailable(record, "Fetch updates remote-tracking metadata and normally does not require an undo action.")
        case .merge, .rebase, .cherryPick, .revert, .resetHard:
            return unavailable(record, "This operation requires a dedicated recovery executor and stronger working-tree checkpoints.")
        }
    }

    private static func unavailable(_ record: GitOperationRecord, _ reason: String) -> GitRecoveryPlan {
        GitRecoveryPlan(
            sourceOperationID: record.id,
            availability: .unavailable,
            inverseIntent: nil,
            reason: reason
        )
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
