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

public enum GitMutationAdmissionError: LocalizedError, Sendable {
    case blocked(GitPreflightReport)
    case confirmationRequired(GitPreflightReport)

    public var errorDescription: String? {
        switch self {
        case .blocked(let report):
            return report.blockingReasons.first ?? "The Git operation is blocked by the current repository state."
        case .confirmationRequired(let report):
            return report.warnings.first ?? "This Git operation requires explicit confirmation."
        }
    }
}

public extension GitService {
    func mutationAdmission(
        at repositoryURL: URL,
        intent: GitMutationIntent,
        confirmationProvided: Bool = false
    ) async throws -> GitMutationAdmission {
        let intelligence = try await repositoryIntelligence(at: repositoryURL)
        let report = GitSafetyPreflight.evaluate(intent: intent, intelligence: intelligence)
        return GitMutationAdmission(report: report, confirmationProvided: confirmationProvided)
    }

    @discardableResult
    func requireMutationAdmission(
        at repositoryURL: URL,
        intent: GitMutationIntent,
        confirmationProvided: Bool = false
    ) async throws -> GitPreflightReport {
        let admission = try await mutationAdmission(
            at: repositoryURL,
            intent: intent,
            confirmationProvided: confirmationProvided
        )
        switch admission.state {
        case .allowed:
            return admission.report
        case .confirmationRequired:
            throw GitMutationAdmissionError.confirmationRequired(admission.report)
        case .blocked:
            throw GitMutationAdmissionError.blocked(admission.report)
        }
    }
}

public struct GitConflictFile: Hashable, Identifiable, Sendable {
    public let path: String
    public let base: String?
    public let ours: String?
    public let theirs: String?
    public let result: String?

    public var id: String { path }

    public init(path: String, base: String?, ours: String?, theirs: String?, result: String?) {
        self.path = path
        self.base = base
        self.ours = ours
        self.theirs = theirs
        self.result = result
    }
}

public enum GitConflictWorkspaceError: LocalizedError, Sendable {
    case notConflicted(String)
    case invalidPath(String)
    case unsupportedBinary(String)
    case fileTooLarge(String)
    case unreadableResult(String)

    public var errorDescription: String? {
        switch self {
        case .notConflicted(let path):
            return "\(path) is not an active conflicted path."
        case .invalidPath(let path):
            return "The conflict path is outside the repository: \(path)."
        case .unsupportedBinary(let path):
            return "Binary conflict resolution is not supported for \(path)."
        case .fileTooLarge(let path):
            return "\(path) is too large for the text conflict workspace."
        case .unreadableResult(let path):
            return "The working-tree result for \(path) could not be read as UTF-8 text."
        }
    }
}

public extension SystemGitEngine {
    func conflictFile(
        at repositoryURL: URL,
        path: String,
        maximumBytes: Int = 2 * 1024 * 1024
    ) throws -> GitConflictFile {
        let root = try repositoryRoot(for: repositoryURL).standardizedFileURL
        let snapshot = try status(at: root)
        guard snapshot.paths.contains(where: { $0.path == path && $0.kind == .conflicted }) else {
            throw GitConflictWorkspaceError.notConflicted(path)
        }

        let resultURL = try validatedConflictPath(path, root: root)
        let base = try conflictStageText(stage: 1, path: path, root: root, maximumBytes: maximumBytes)
        let ours = try conflictStageText(stage: 2, path: path, root: root, maximumBytes: maximumBytes)
        let theirs = try conflictStageText(stage: 3, path: path, root: root, maximumBytes: maximumBytes)

        let result: String?
        if FileManager.default.fileExists(atPath: resultURL.path) {
            let data = try Data(contentsOf: resultURL, options: [.mappedIfSafe])
            try validateConflictTextData(data, path: path, maximumBytes: maximumBytes)
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw GitConflictWorkspaceError.unreadableResult(path)
            }
            result = decoded
        } else {
            result = nil
        }

        return GitConflictFile(path: path, base: base, ours: ours, theirs: theirs, result: result)
    }

    private func validatedConflictPath(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, path != ".", !path.hasPrefix("/"), !path.contains("\0") else {
            throw GitConflictWorkspaceError.invalidPath(path)
        }
        let candidate = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw GitConflictWorkspaceError.invalidPath(path)
        }
        return candidate
    }

    private func conflictStageText(
        stage: Int,
        path: String,
        root: URL,
        maximumBytes: Int
    ) throws -> String? {
        let result = try runConflictGit(
            ["-C", root.path, "show", ":\(stage):\(path)"]
        )
        if result.status != 0 {
            return nil
        }
        try validateConflictTextData(result.stdout, path: path, maximumBytes: maximumBytes)
        guard let text = String(data: result.stdout, encoding: .utf8) else {
            throw GitConflictWorkspaceError.unsupportedBinary(path)
        }
        return text
    }

    private func validateConflictTextData(_ data: Data, path: String, maximumBytes: Int) throws {
        let boundedMaximum = max(1, maximumBytes)
        guard data.count <= boundedMaximum else {
            throw GitConflictWorkspaceError.fileTooLarge(path)
        }
        guard !data.contains(0) else {
            throw GitConflictWorkspaceError.unsupportedBinary(path)
        }
    }

    private func runConflictGit(_ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitEngineError.executableMissing(executableURL.path)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }

        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            stdout,
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
