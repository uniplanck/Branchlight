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
