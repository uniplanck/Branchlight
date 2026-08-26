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

public enum GitRecoveryValidationIssue: String, Codable, CaseIterable, Hashable, Sendable {
    case unavailablePlan
    case sourceOperationMismatch
    case operationNotSucceeded
    case missingPostCheckpoint
    case headChanged
    case indexChanged
    case branchChanged
    case detachedHeadChanged
    case operationInProgress
    case workingTreeNotClean
    case unsupportedExactIndexRestore
    case missingRecoveryTarget
}

public struct GitRecoveryValidation: Codable, Hashable, Sendable {
    public let issues: Set<GitRecoveryValidationIssue>

    public init(issues: Set<GitRecoveryValidationIssue>) {
        self.issues = issues
    }

    public var isValid: Bool { issues.isEmpty }
}

public enum GitRecoveryAction: Codable, Hashable, Sendable {
    case switchBranch(String)
    case revertCommit(String)
    case removeWorktree(String)
}

public enum GitRecoveryValidationError: LocalizedError, Sendable {
    case rejected(Set<GitRecoveryValidationIssue>)

    public var errorDescription: String? {
        switch self {
        case .rejected(let issues):
            return "Recovery validation failed: \(issues.map(\.rawValue).sorted().joined(separator: ", "))."
        }
    }
}

public enum GitRecoveryValidator {
    public static func validate(
        plan: GitRecoveryPlan,
        sourceRecord: GitOperationRecord,
        currentCheckpoint: GitRepositoryCheckpoint,
        currentStatus: GitStatusSnapshot? = nil
    ) -> GitRecoveryValidation {
        var issues: Set<GitRecoveryValidationIssue> = []

        guard plan.availability == .validationRequired else {
            return GitRecoveryValidation(issues: [.unavailablePlan])
        }

        if plan.sourceOperationID != sourceRecord.id {
            issues.insert(.sourceOperationMismatch)
        }
        if sourceRecord.state != .succeeded {
            issues.insert(.operationNotSucceeded)
        }
        guard let post = sourceRecord.postCheckpoint else {
            issues.insert(.missingPostCheckpoint)
            return GitRecoveryValidation(issues: issues)
        }

        if let expectedHead = plan.expectedCurrentHead, currentCheckpoint.headCommit != expectedHead {
            issues.insert(.headChanged)
        }
        if let expectedIndex = plan.expectedCurrentIndexTree, currentCheckpoint.indexTree != expectedIndex {
            issues.insert(.indexChanged)
        }
        if currentCheckpoint.branch != post.branch {
            issues.insert(.branchChanged)
        }
        if currentCheckpoint.isDetachedHead != post.isDetachedHead {
            issues.insert(.detachedHeadChanged)
        }
        if currentCheckpoint.operationMode != .normal {
            issues.insert(.operationInProgress)
        }

        switch plan.inverseIntent {
        case .stage, .unstage:
            // A tree hash proves index equality but does not preserve every index-only bit
            // (for example intent-to-add/sparse-index details). Until the actual index is
            // durably checkpointed, an automatic exact restore would over-promise safety.
            issues.insert(.unsupportedExactIndexRestore)
        case .switchBranch, .revert:
            if let currentStatus, !currentStatus.isClean {
                issues.insert(.workingTreeNotClean)
            }
            if plan.target?.isEmpty != false {
                issues.insert(.missingRecoveryTarget)
            }
        case .worktreeRemove:
            if plan.target?.isEmpty != false {
                issues.insert(.missingRecoveryTarget)
            }
        case .none:
            issues.insert(.unavailablePlan)
        default:
            issues.insert(.unavailablePlan)
        }

        return GitRecoveryValidation(issues: issues)
    }

    public static func validatedAction(
        plan: GitRecoveryPlan,
        sourceRecord: GitOperationRecord,
        currentCheckpoint: GitRepositoryCheckpoint,
        currentStatus: GitStatusSnapshot? = nil
    ) throws -> GitRecoveryAction {
        let validation = validate(
            plan: plan,
            sourceRecord: sourceRecord,
            currentCheckpoint: currentCheckpoint,
            currentStatus: currentStatus
        )
        guard validation.isValid else {
            throw GitRecoveryValidationError.rejected(validation.issues)
        }
        guard let target = plan.target else {
            throw GitRecoveryValidationError.rejected([.missingRecoveryTarget])
        }

        switch plan.inverseIntent {
        case .switchBranch:
            return .switchBranch(target)
        case .revert:
            return .revertCommit(target)
        case .worktreeRemove:
            return .removeWorktree(target)
        default:
            throw GitRecoveryValidationError.rejected([.unavailablePlan])
        }
    }
}

public enum GitMutationAdmissionState: String, Codable, Hashable, Sendable {
    case allowed
    case confirmationRequired
    case blocked
}

public struct GitMutationAdmission: Codable, Hashable, Sendable {
    public let report: GitPreflightReport
    public let state: GitMutationAdmissionState

    public init(report: GitPreflightReport, confirmationProvided: Bool = false) {
        self.report = report
        if !report.canProceed {
            state = .blocked
        } else if report.requiresConfirmation && !confirmationProvided {
            state = .confirmationRequired
        } else {
            state = .allowed
        }
    }

    public var mayExecute: Bool { state == .allowed }
}
