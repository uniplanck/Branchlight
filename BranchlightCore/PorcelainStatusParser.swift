import Foundation

public enum PorcelainStatusParser {
    public static func parse(_ data: Data) throws -> [GitPathStatus] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var result: [GitPathStatus] = []
        var index = 0

        while index < records.count {
            let record = records[index]
            guard record.count >= 4 else {
                index += 1
                continue
            }

            guard let string = String(data: Data(record), encoding: .utf8) else {
                throw GitEngineError.invalidOutput("git status produced non-UTF-8 path data")
            }

            let characters = Array(string)
            guard characters.count >= 4 else {
                index += 1
                continue
            }

            let indexCode = String(characters[0])
            let workTreeCode = String(characters[1])
            let path = String(characters.dropFirst(3))
            let kind = GitStatusClassifier.classify(index: indexCode, workTree: workTreeCode)

            result.append(
                GitPathStatus(
                    path: path,
                    indexCode: indexCode,
                    workTreeCode: workTreeCode,
                    kind: kind
                )
            )

            if indexCode == "R" || indexCode == "C" || workTreeCode == "R" || workTreeCode == "C" {
                index += 1 // porcelain -z emits the second path as the following NUL record
            }
            index += 1
        }

        return result
    }
}

public extension SystemGitEngine {
    func cherryPickCommit(at repositoryURL: URL, commitHash: String) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let commit = try validatedCommitHash(commitHash, at: root)
        return try runHistoryMutation(["-C", root.path, "cherry-pick", commit])
    }

    func continueCherryPick(at repositoryURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        return try runHistoryMutation(["-c", "core.editor=true", "-C", root.path, "cherry-pick", "--continue"])
    }

    func abortCherryPick(at repositoryURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        return try runHistoryMutation(["-C", root.path, "cherry-pick", "--abort"])
    }

    func revertCommit(at repositoryURL: URL, commitHash: String) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let commit = try validatedCommitHash(commitHash, at: root)
        return try runHistoryMutation(["-C", root.path, "revert", "--no-edit", commit])
    }

    func continueRevert(at repositoryURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        return try runHistoryMutation(["-c", "core.editor=true", "-C", root.path, "revert", "--continue"])
    }

    func abortRevert(at repositoryURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        return try runHistoryMutation(["-C", root.path, "revert", "--abort"])
    }

    private func validatedCommitHash(_ rawHash: String, at root: URL) throws -> String {
        let hash = rawHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSupportedLength = hash.count == 40 || hash.count == 64
        guard isSupportedLength,
              hash.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (65...70).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw GitEngineError.invalidInput("Choose a full Git commit hash from repository history.")
        }

        let resolved = try runHistoryMutationAllowingFailure([
            "-C", root.path,
            "rev-parse", "--verify", "\(hash)^{commit}"
        ])
        guard resolved.status == 0 else {
            throw GitEngineError.invalidInput("The selected commit does not exist in this repository.")
        }
        let canonical = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canonical.count == 40 || canonical.count == 64 else {
            throw GitEngineError.invalidOutput("Git returned an invalid commit identifier.")
        }
        return canonical
    }

    private func runHistoryMutation(_ arguments: [String]) throws -> GitCommandResult {
        let result = try runHistoryMutationAllowingFailure(arguments)
        guard result.status == 0 else {
            throw GitEngineError.commandFailed(arguments: arguments, status: result.status, stderr: result.stderr)
        }
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    private func runHistoryMutationAllowingFailure(
        _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
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
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

public protocol GitHistoryMutationService: Sendable {
    func cherryPick(
        at repositoryURL: URL,
        commitHash: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult
    func continueCherryPick(at repositoryURL: URL) async throws -> GitCommandResult
    func abortCherryPick(at repositoryURL: URL) async throws -> GitCommandResult
    func revert(
        at repositoryURL: URL,
        commitHash: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult
    func continueRevert(at repositoryURL: URL) async throws -> GitCommandResult
    func abortRevert(at repositoryURL: URL) async throws -> GitCommandResult
}

public struct CoordinatedGitHistoryMutationService: GitHistoryMutationService, Sendable {
    private let engine: SystemGitEngine
    private let coordinator: GitOperationCoordinator
    private let base: InProcessGitService

    public init(
        engine: SystemGitEngine,
        coordinator: GitOperationCoordinator,
        base: InProcessGitService
    ) {
        self.engine = engine
        self.coordinator = coordinator
        self.base = base
    }

    public func cherryPick(
        at repositoryURL: URL,
        commitHash: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await startHistoryMutation(
            at: repositoryURL,
            label: "cherry-pick \(String(commitHash.prefix(12)))",
            descriptor: GitOperationDescriptor(
                intent: .cherryPick,
                reference: commitHash,
                parameters: ["control": "start"]
            ),
            confirmationProvided: confirmationProvided
        ) { engine, root in
            try engine.cherryPickCommit(at: root, commitHash: commitHash)
        }
    }

    public func continueCherryPick(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlHistoryMutation(
            at: repositoryURL,
            label: "continue cherry-pick",
            descriptor: GitOperationDescriptor(intent: .cherryPick, parameters: ["control": "continue"]),
            expectedMode: .cherryPicking,
            requiresResolvedConflicts: true
        ) { engine, root in
            try engine.continueCherryPick(at: root)
        }
    }

    public func abortCherryPick(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlHistoryMutation(
            at: repositoryURL,
            label: "abort cherry-pick",
            descriptor: GitOperationDescriptor(intent: .cherryPick, parameters: ["control": "abort"]),
            expectedMode: .cherryPicking
        ) { engine, root in
            try engine.abortCherryPick(at: root)
        }
    }

    public func revert(
        at repositoryURL: URL,
        commitHash: String,
        confirmationProvided: Bool
    ) async throws -> GitCommandResult {
        try await startHistoryMutation(
            at: repositoryURL,
            label: "revert \(String(commitHash.prefix(12)))",
            descriptor: GitOperationDescriptor(
                intent: .revert,
                reference: commitHash,
                parameters: ["control": "start"]
            ),
            confirmationProvided: confirmationProvided
        ) { engine, root in
            try engine.revertCommit(at: root, commitHash: commitHash)
        }
    }

    public func continueRevert(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlHistoryMutation(
            at: repositoryURL,
            label: "continue revert",
            descriptor: GitOperationDescriptor(intent: .revert, parameters: ["control": "continue"]),
            expectedMode: .reverting,
            requiresResolvedConflicts: true
        ) { engine, root in
            try engine.continueRevert(at: root)
        }
    }

    public func abortRevert(at repositoryURL: URL) async throws -> GitCommandResult {
        try await controlHistoryMutation(
            at: repositoryURL,
            label: "abort revert",
            descriptor: GitOperationDescriptor(intent: .revert, parameters: ["control": "abort"]),
            expectedMode: .reverting
        ) { engine, root in
            try engine.abortRevert(at: root)
        }
    }

    private func startHistoryMutation<T: Sendable>(
        at repositoryURL: URL,
        label: String,
        descriptor: GitOperationDescriptor,
        confirmationProvided: Bool,
        operation: @escaping @Sendable (SystemGitEngine, URL) throws -> T
    ) async throws -> T {
        let identity = try await base.repositoryIdentity(at: repositoryURL)
        let checkpointProvider = checkpointProvider(for: identity)
        let engine = engine
        let base = base

        return try await coordinator.run(
            repository: identity,
            label: label,
            descriptor: descriptor,
            checkpointProvider: checkpointProvider
        ) {
            let intelligence = try await base.repositoryIntelligence(at: identity.repositoryURL)
            let report = GitSafetyPreflight.evaluate(intent: descriptor.intent, intelligence: intelligence)
            let admission = GitMutationAdmission(report: report, confirmationProvided: confirmationProvided)
            switch admission.state {
            case .allowed:
                break
            case .confirmationRequired:
                throw GitMutationAdmissionError.confirmationRequired(report)
            case .blocked:
                throw GitMutationAdmissionError.blocked(report)
            }

            return try await Task.detached(priority: .userInitiated) {
                try operation(engine, identity.repositoryURL)
            }.value
        }
    }

    private func controlHistoryMutation<T: Sendable>(
        at repositoryURL: URL,
        label: String,
        descriptor: GitOperationDescriptor,
        expectedMode: GitRepositoryOperationMode,
        requiresResolvedConflicts: Bool = false,
        operation: @escaping @Sendable (SystemGitEngine, URL) throws -> T
    ) async throws -> T {
        let identity = try await base.repositoryIdentity(at: repositoryURL)
        let checkpointProvider = checkpointProvider(for: identity)
        let engine = engine
        let base = base

        return try await coordinator.run(
            repository: identity,
            label: label,
            descriptor: descriptor,
            checkpointProvider: checkpointProvider
        ) {
            let intelligence = try await base.repositoryIntelligence(at: identity.repositoryURL)
            guard intelligence.operationMode == expectedMode else {
                throw GitEngineError.invalidInput(
                    "The requested history operation control does not match the repository's current operation state."
                )
            }
            if requiresResolvedConflicts, intelligence.conflictCount > 0 {
                throw GitEngineError.invalidInput("Resolve and stage all conflicts before continuing this operation.")
            }

            return try await Task.detached(priority: .userInitiated) {
                try operation(engine, identity.repositoryURL)
            }.value
        }
    }

    private func checkpointProvider(
        for identity: GitRepositoryIdentity
    ) -> @Sendable () async -> GitRepositoryCheckpoint? {
        let engine = engine
        let base = base
        return {
            let status = try? await Task.detached(priority: .utility) {
                try engine.status(at: identity.repositoryURL)
            }.value
            let intelligence = try? await base.repositoryIntelligence(at: identity.repositoryURL)
            let head = try? Self.gitOutput(
                executableURL: engine.executableURL,
                arguments: ["-C", identity.workingTreeRoot, "rev-parse", "--verify", "HEAD"]
            )
            let indexTree = try? Self.gitOutput(
                executableURL: engine.executableURL,
                arguments: ["-C", identity.workingTreeRoot, "write-tree"]
            )

            guard let status else { return nil }
            return GitRepositoryCheckpoint(
                headCommit: head,
                branch: status.isDetachedHead ? nil : status.branch,
                isDetachedHead: status.isDetachedHead,
                indexTree: indexTree,
                operationMode: intelligence?.operationMode ?? .normal
            )
        }
    }

    private static func gitOutput(
        executableURL: URL,
        arguments: [String]
    ) throws -> String {
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
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitEngineError.commandFailed(
                arguments: arguments,
                status: process.terminationStatus,
                stderr: String(data: stderr, encoding: .utf8) ?? ""
            )
        }
        return (String(data: stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
