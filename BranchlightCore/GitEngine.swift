import Foundation

public enum GitEngineError: LocalizedError, Sendable {
    case executableMissing(String)
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    case invalidOutput(String)
    case notRepository(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "Git executable was not found at \(path)."
        case .commandFailed(let arguments, let status, let stderr):
            let command = arguments.joined(separator: " ")
            return "git \(command) failed (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .invalidOutput(let message):
            return message
        case .notRepository(let path):
            return "No Git repository was found for \(path)."
        case .invalidInput(let message):
            return message
        }
    }
}

public protocol GitEngine: Sendable {
    func repositoryRoot(for url: URL) throws -> URL
    func status(at repositoryURL: URL) throws -> GitStatusSnapshot
    func diff(at repositoryURL: URL, paths: [String], staged: Bool) throws -> String
    func structuredDiff(at repositoryURL: URL, paths: [String], staged: Bool) throws -> [GitDiffFile]
    func stage(at repositoryURL: URL, paths: [String]) throws
    func unstage(at repositoryURL: URL, paths: [String]) throws
    func applyPatch(at repositoryURL: URL, patch: String, reverse: Bool) throws
    func commit(at repositoryURL: URL, message: String, amend: Bool) throws -> GitCommandResult
    func fetch(at repositoryURL: URL) throws -> GitCommandResult
    func pullFastForwardOnly(at repositoryURL: URL) throws -> GitCommandResult
    func push(at repositoryURL: URL) throws -> GitCommandResult
    func branches(at repositoryURL: URL) throws -> [GitBranch]
    func switchBranch(at repositoryURL: URL, name: String) throws
    func history(at repositoryURL: URL, limit: Int) throws -> [GitCommit]
    func fileHistory(at repositoryURL: URL, path: String, limit: Int) throws -> [GitCommit]
    func blame(at repositoryURL: URL, path: String) throws -> [GitBlameLine]
    func stashes(at repositoryURL: URL) throws -> [GitStashEntry]
    func createStash(at repositoryURL: URL, message: String, includeUntracked: Bool) throws -> GitCommandResult
    func applyStash(at repositoryURL: URL, reference: String, pop: Bool) throws -> GitCommandResult
    func dropStash(at repositoryURL: URL, reference: String) throws -> GitCommandResult
    func worktrees(at repositoryURL: URL) throws -> [GitWorktree]
    func addWorktree(at repositoryURL: URL, path: URL, branch: String) throws -> GitCommandResult
    func addWorktree(at repositoryURL: URL, path: URL, newBranch: String, startPoint: String) throws -> GitCommandResult
    func removeWorktree(at repositoryURL: URL, path: URL) throws -> GitCommandResult
}

public struct SystemGitEngine: GitEngine, Sendable {
    public let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executableURL = executableURL
    }

    public func repositoryRoot(for url: URL) throws -> URL {
        let candidate = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let result = try run(["-C", candidate.path, "rev-parse", "--show-toplevel"])
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw GitEngineError.notRepository(url.path) }
        return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    }

    public func status(at repositoryURL: URL) throws -> GitStatusSnapshot {
        let root = try repositoryRoot(for: repositoryURL)
        let statusResult = try runData([
            "--no-optional-locks",
            "-C", root.path,
            "status", "--porcelain=v1", "-z", "--untracked-files=all"
        ])
        let paths = try PorcelainStatusParser.parse(statusResult.stdout)

        let branchResult = try runAllowingFailure([
            "-C", root.path,
            "symbolic-ref", "--quiet", "--short", "HEAD"
        ])

        let isDetached = branchResult.status != 0
        let branch: String
        if isDetached {
            let detached = try run(["-C", root.path, "rev-parse", "--short", "HEAD"])
            branch = detached.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return GitStatusSnapshot(
            repositoryRoot: root.path,
            branch: branch,
            isDetachedHead: isDetached,
            paths: paths
        )
    }

    public func diff(at repositoryURL: URL, paths: [String] = [], staged: Bool = false) throws -> String {
        let root = try repositoryRoot(for: repositoryURL)
        var arguments = ["-C", root.path, "diff", "--no-ext-diff", "--no-color"]
        if staged { arguments.append("--cached") }
        if !paths.isEmpty {
            arguments.append("--")
            arguments.append(contentsOf: paths)
        }
        return try run(arguments).stdout
    }

    public func structuredDiff(at repositoryURL: URL, paths: [String] = [], staged: Bool = false) throws -> [GitDiffFile] {
        try GitDiffParser.parse(diff(at: repositoryURL, paths: paths, staged: staged))
    }

    public func stage(at repositoryURL: URL, paths: [String]) throws {
        guard !paths.isEmpty else { throw GitEngineError.invalidInput("Select at least one path to stage.") }
        let root = try repositoryRoot(for: repositoryURL)
        _ = try run(["-C", root.path, "add", "--"] + paths)
    }

    public func unstage(at repositoryURL: URL, paths: [String]) throws {
        guard !paths.isEmpty else { throw GitEngineError.invalidInput("Select at least one path to unstage.") }
        let root = try repositoryRoot(for: repositoryURL)

        let hasHead = try runAllowingFailure(["-C", root.path, "rev-parse", "--verify", "HEAD"]).status == 0
        if hasHead {
            _ = try run(["-C", root.path, "restore", "--staged", "--"] + paths)
        } else {
            _ = try run(["-C", root.path, "rm", "--cached", "-r", "--ignore-unmatch", "--"] + paths)
        }
    }

    public func applyPatch(at repositoryURL: URL, patch: String, reverse: Bool = false) throws {
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitEngineError.invalidInput("Patch cannot be empty.")
        }
        let root = try repositoryRoot(for: repositoryURL)
        var arguments = ["-C", root.path, "apply", "--cached", "--recount", "--whitespace=nowarn"]
        if reverse { arguments.append("--reverse") }
        _ = try run(arguments, stdin: Data(patch.utf8))
    }

    public func commit(
        at repositoryURL: URL,
        message: String,
        amend: Bool = false
    ) throws -> GitCommandResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitEngineError.invalidInput("Commit message cannot be empty.") }

        let root = try repositoryRoot(for: repositoryURL)
        var arguments = ["-C", root.path, "commit", "-m", trimmed]
        if amend { arguments.append("--amend") }
        let result = try run(arguments)
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func fetch(at repositoryURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let result = try run(["-C", root.path, "fetch", "--prune"])
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func pullFastForwardOnly(at repositoryURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let result = try run(["-C", root.path, "pull", "--ff-only"])
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func push(at repositoryURL: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let result = try run(["-C", root.path, "push"])
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func branches(at repositoryURL: URL) throws -> [GitBranch] {
        let root = try repositoryRoot(for: repositoryURL)
        let format = "%(refname:short)%09%(HEAD)%09%(upstream:short)"
        let result = try run(["-C", root.path, "for-each-ref", "--format=\(format)", "refs/heads"])

        var branches: [GitBranch] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { continue }
            branches.append(
                GitBranch(
                    name: fields[0],
                    isCurrent: fields[1] == "*",
                    upstream: fields[2].isEmpty ? nil : fields[2]
                )
            )
        }

        return branches.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func switchBranch(at repositoryURL: URL, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitEngineError.invalidInput("Branch name cannot be empty.") }
        let root = try repositoryRoot(for: repositoryURL)
        _ = try run(["-C", root.path, "switch", "--", trimmed])
    }

    public func history(at repositoryURL: URL, limit: Int = 30) throws -> [GitCommit] {
        let root = try repositoryRoot(for: repositoryURL)
        return try logCommits(at: root, arguments: [], limit: limit)
    }

    public func fileHistory(at repositoryURL: URL, path: String, limit: Int = 50) throws -> [GitCommit] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else {
            throw GitEngineError.invalidInput("Choose one file for file history.")
        }
        let root = try repositoryRoot(for: repositoryURL)
        return try logCommits(at: root, arguments: ["--follow", "--", trimmed], limit: limit)
    }

    public func blame(at repositoryURL: URL, path: String) throws -> [GitBlameLine] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else {
            throw GitEngineError.invalidInput("Choose one file for blame.")
        }
        let root = try repositoryRoot(for: repositoryURL)
        let result = try run(["-C", root.path, "blame", "--line-porcelain", "--", trimmed])
        return try parseBlamePorcelain(result.stdout)
    }

    public func stashes(at repositoryURL: URL) throws -> [GitStashEntry] {
        let root = try repositoryRoot(for: repositoryURL)
        let format = "%gd%x1f%H%x1f%gs%x1e"
        let result = try run(["-C", root.path, "stash", "list", "--format=\(format)"])
        return result.stdout
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 3 else { return nil }
                let reference = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let index = stashIndex(from: reference) else { return nil }
                return GitStashEntry(
                    index: index,
                    reference: reference,
                    commitHash: fields[1],
                    message: fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .sorted { $0.index < $1.index }
    }

    public func createStash(
        at repositoryURL: URL,
        message: String,
        includeUntracked: Bool = true
    ) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["-C", root.path, "stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        arguments += ["--message", trimmed.isEmpty ? "Branchlight stash" : trimmed]
        let result = try run(arguments)
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func applyStash(
        at repositoryURL: URL,
        reference: String,
        pop: Bool = false
    ) throws -> GitCommandResult {
        let validated = try validateStashReference(reference)
        let root = try repositoryRoot(for: repositoryURL)
        let action = pop ? "pop" : "apply"
        let result = try run(["-C", root.path, "stash", action, validated])
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func dropStash(at repositoryURL: URL, reference: String) throws -> GitCommandResult {
        let validated = try validateStashReference(reference)
        let root = try repositoryRoot(for: repositoryURL)
        let result = try run(["-C", root.path, "stash", "drop", validated])
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func worktrees(at repositoryURL: URL) throws -> [GitWorktree] {
        let root = try repositoryRoot(for: repositoryURL)
        let result = try run(["-C", root.path, "worktree", "list", "--porcelain"])
        return parseWorktreePorcelain(result.stdout)
    }

    public func addWorktree(at repositoryURL: URL, path: URL, branch: String) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let validatedBranch = try validateBranchName(branch, at: root)
        let destination = try validateWorktreeDestination(path, repositoryRoot: root)
        let result = try run(["-C", root.path, "worktree", "add", destination.path, validatedBranch])
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func addWorktree(
        at repositoryURL: URL,
        path: URL,
        newBranch: String,
        startPoint: String = "HEAD"
    ) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let validatedBranch = try validateBranchName(newBranch, at: root)
        let destination = try validateWorktreeDestination(path, repositoryRoot: root)
        let trimmedStart = startPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStart.isEmpty else { throw GitEngineError.invalidInput("Start point cannot be empty.") }
        let resolved = try run(["-C", root.path, "rev-parse", "--verify", "\(trimmedStart)^{commit}"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { throw GitEngineError.invalidOutput("Could not resolve worktree start point.") }
        let result = try run(["-C", root.path, "worktree", "add", "-b", validatedBranch, destination.path, resolved])
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    public func removeWorktree(at repositoryURL: URL, path: URL) throws -> GitCommandResult {
        let root = try repositoryRoot(for: repositoryURL)
        let destination = path.standardizedFileURL
        guard destination.path != root.standardizedFileURL.path else {
            throw GitEngineError.invalidInput("The primary repository worktree cannot be removed here.")
        }
        guard try worktrees(at: root).contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == destination.path }) else {
            throw GitEngineError.invalidInput("The selected path is not a registered worktree.")
        }
        let result = try run(["-C", root.path, "worktree", "remove", destination.path])
        return GitCommandResult(stdout: result.stdout, stderr: result.stderr)
    }

    private func logCommits(at root: URL, arguments: [String], limit: Int) throws -> [GitCommit] {
        let boundedLimit = min(max(limit, 1), 500)
        let format = "%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1e"
        let result = try run(["-C", root.path, "log", "--no-decorate", "--format=\(format)", "-n", "\(boundedLimit)"] + arguments)
        let records = result.stdout.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        let formatter = ISO8601DateFormatter()

        return records.compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { return nil }
            return GitCommit(
                hash: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                shortHash: fields[1],
                author: fields[2],
                authoredAt: formatter.date(from: fields[3]),
                subject: fields[4]
            )
        }
    }

    private func parseBlamePorcelain(_ output: String) throws -> [GitBlameLine] {
        var result: [GitBlameLine] = []
        var commitHash = ""
        var finalLine = 0
        var author = ""
        var authoredAt: Date?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.first == "\t" {
                guard !commitHash.isEmpty, finalLine > 0 else {
                    throw GitEngineError.invalidOutput("Malformed git blame porcelain output.")
                }
                result.append(
                    GitBlameLine(
                        lineNumber: finalLine,
                        commitHash: commitHash,
                        author: author,
                        authoredAt: authoredAt,
                        content: String(line.dropFirst())
                    )
                )
                continue
            }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3, fields[0].count >= 7, Int(fields[1]) != nil, let parsedLine = Int(fields[2]) {
                commitHash = String(fields[0])
                finalLine = parsedLine
                author = ""
                authoredAt = nil
            } else if line.hasPrefix("author ") {
                author = String(line.dropFirst(7))
            } else if line.hasPrefix("author-time "), let seconds = TimeInterval(String(line.dropFirst(12))) {
                authoredAt = Date(timeIntervalSince1970: seconds)
            }
        }

        return result
    }

    private func parseWorktreePorcelain(_ output: String) -> [GitWorktree] {
        let blocks = output.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return blocks.compactMap { block in
            var path: String?
            var head = ""
            var branch: String?
            var isBare = false
            var isDetached = false
            var isLocked = false
            var lockReason: String?

            for line in block.split(whereSeparator: \.isNewline).map(String.init) {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst(9))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst(5))
                } else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst(7))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
                } else if line == "bare" {
                    isBare = true
                } else if line == "detached" {
                    isDetached = true
                } else if line == "locked" {
                    isLocked = true
                } else if line.hasPrefix("locked ") {
                    isLocked = true
                    lockReason = String(line.dropFirst(7))
                }
            }

            guard let path else { return nil }
            let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            return GitWorktree(
                path: normalizedPath,
                head: head,
                branch: branch,
                isBare: isBare,
                isDetached: isDetached,
                isLocked: isLocked,
                lockReason: lockReason
            )
        }
    }

    private func stashIndex(from reference: String) -> Int? {
        guard reference.hasPrefix("stash@{"), reference.hasSuffix("}") else { return nil }
        return Int(reference.dropFirst(7).dropLast())
    }

    private func validateStashReference(_ reference: String) throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stashIndex(from: trimmed) != nil else {
            throw GitEngineError.invalidInput("Invalid stash reference.")
        }
        return trimmed
    }

    private func validateBranchName(_ branch: String, at root: URL) throws -> String {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitEngineError.invalidInput("Branch name cannot be empty.") }
        let check = try runAllowingFailure(["-C", root.path, "check-ref-format", "--branch", trimmed])
        guard check.status == 0 else { throw GitEngineError.invalidInput("Invalid branch name: \(trimmed)") }
        return trimmed
    }

    private func validateWorktreeDestination(_ url: URL, repositoryRoot: URL) throws -> URL {
        let destination = url.standardizedFileURL
        guard destination.isFileURL, destination.path.hasPrefix("/") else {
            throw GitEngineError.invalidInput("Choose an absolute local path for the worktree.")
        }
        guard destination.path != repositoryRoot.standardizedFileURL.path else {
            throw GitEngineError.invalidInput("Choose a different directory for the worktree.")
        }
        return destination
    }

    private func run(_ arguments: [String], stdin: Data? = nil) throws -> (stdout: String, stderr: String) {
        let result = try runAllowingFailure(arguments, stdin: stdin)
        guard result.status == 0 else {
            throw GitEngineError.commandFailed(arguments: arguments, status: result.status, stderr: result.stderr)
        }
        return (result.stdout, result.stderr)
    }

    private func runData(_ arguments: [String]) throws -> (stdout: Data, stderr: String) {
        let result = try execute(arguments)
        guard result.status == 0 else {
            throw GitEngineError.commandFailed(arguments: arguments, status: result.status, stderr: result.stderr)
        }
        return (result.stdout, result.stderr)
    }

    private func runAllowingFailure(_ arguments: [String], stdin: Data? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try execute(arguments, stdin: stdin)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        return (result.status, stdout, result.stderr)
    }

    private func execute(_ arguments: [String], stdin: Data? = nil) throws -> (status: Int32, stdout: Data, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitEngineError.executableMissing(executableURL.path)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = stdin == nil ? nil : Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe { process.standardInput = stdinPipe }
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }

        try process.run()
        if let stdin, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
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
