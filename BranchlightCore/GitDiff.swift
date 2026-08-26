import Foundation

public enum GitDiffLineKind: String, Codable, Sendable {
    case context
    case addition
    case deletion
    case metadata
}

public struct GitDiffLine: Codable, Hashable, Identifiable, Sendable {
    public let ordinal: Int
    public let kind: GitDiffLineKind
    public let text: String
    public let raw: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public var id: Int { ordinal }
    public var isChange: Bool { kind == .addition || kind == .deletion }

    public init(
        ordinal: Int,
        kind: GitDiffLineKind,
        text: String,
        raw: String,
        oldLineNumber: Int?,
        newLineNumber: Int?
    ) {
        self.ordinal = ordinal
        self.kind = kind
        self.text = text
        self.raw = raw
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

public struct GitDiffHunk: Codable, Hashable, Identifiable, Sendable {
    public let ordinal: Int
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let section: String
    public let lines: [GitDiffLine]

    public var id: Int { ordinal }
    public var changedLineCount: Int { lines.count(where: \.isChange) }

    public init(
        ordinal: Int,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        section: String,
        lines: [GitDiffLine]
    ) {
        self.ordinal = ordinal
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    public var header: String {
        let oldRange = Self.rangeText(start: oldStart, count: oldCount)
        let newRange = Self.rangeText(start: newStart, count: newCount)
        return "@@ -\(oldRange) +\(newRange) @@\(section)"
    }

    private static func rangeText(start: Int, count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }
}

public struct GitDiffFile: Codable, Hashable, Identifiable, Sendable {
    public let ordinal: Int
    public let oldPath: String
    public let newPath: String
    public let headerLines: [String]
    public let hunks: [GitDiffHunk]

    public var id: String { "\(ordinal):\(displayPath)" }
    public var displayPath: String {
        if newPath != "/dev/null" { return newPath }
        return oldPath
    }

    public init(
        ordinal: Int,
        oldPath: String,
        newPath: String,
        headerLines: [String],
        hunks: [GitDiffHunk]
    ) {
        self.ordinal = ordinal
        self.oldPath = oldPath
        self.newPath = newPath
        self.headerLines = headerLines
        self.hunks = hunks
    }
}

public enum GitDiffParser {
    public static func parse(_ text: String) throws -> [GitDiffFile] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var files: [GitDiffFile] = []
        var fileHeader: [String] = []
        var hunks: [GitDiffHunk] = []
        var oldPath = ""
        var newPath = ""
        var currentHunkHeader: HunkHeader?
        var currentHunkLines: [GitDiffLine] = []
        var fileOrdinal = 0
        var hunkOrdinal = 0
        var oldCursor = 0
        var newCursor = 0

        func finishHunk() {
            guard let header = currentHunkHeader else { return }
            hunks.append(
                GitDiffHunk(
                    ordinal: hunkOrdinal,
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    section: header.section,
                    lines: currentHunkLines
                )
            )
            hunkOrdinal += 1
            currentHunkHeader = nil
            currentHunkLines = []
        }

        func finishFile() {
            finishHunk()
            guard !fileHeader.isEmpty || !hunks.isEmpty else { return }
            files.append(
                GitDiffFile(
                    ordinal: fileOrdinal,
                    oldPath: oldPath,
                    newPath: newPath,
                    headerLines: fileHeader,
                    hunks: hunks
                )
            )
            fileOrdinal += 1
            hunkOrdinal = 0
            fileHeader = []
            hunks = []
            oldPath = ""
            newPath = ""
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                finishFile()
                fileHeader.append(line)
                continue
            }

            if line.hasPrefix("@@ ") {
                finishHunk()
                let header = try parseHunkHeader(line)
                currentHunkHeader = header
                oldCursor = header.oldStart
                newCursor = header.newStart
                continue
            }

            if currentHunkHeader != nil {
                let ordinal = currentHunkLines.count
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    currentHunkLines.append(
                        GitDiffLine(
                            ordinal: ordinal,
                            kind: .addition,
                            text: String(line.dropFirst()),
                            raw: line,
                            oldLineNumber: nil,
                            newLineNumber: newCursor
                        )
                    )
                    newCursor += 1
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    currentHunkLines.append(
                        GitDiffLine(
                            ordinal: ordinal,
                            kind: .deletion,
                            text: String(line.dropFirst()),
                            raw: line,
                            oldLineNumber: oldCursor,
                            newLineNumber: nil
                        )
                    )
                    oldCursor += 1
                } else if line.hasPrefix(" ") {
                    currentHunkLines.append(
                        GitDiffLine(
                            ordinal: ordinal,
                            kind: .context,
                            text: String(line.dropFirst()),
                            raw: line,
                            oldLineNumber: oldCursor,
                            newLineNumber: newCursor
                        )
                    )
                    oldCursor += 1
                    newCursor += 1
                } else {
                    currentHunkLines.append(
                        GitDiffLine(
                            ordinal: ordinal,
                            kind: .metadata,
                            text: line,
                            raw: line,
                            oldLineNumber: nil,
                            newLineNumber: nil
                        )
                    )
                }
                continue
            }

            if line.hasPrefix("--- ") {
                oldPath = normalizeDiffPath(String(line.dropFirst(4)))
            } else if line.hasPrefix("+++ ") {
                newPath = normalizeDiffPath(String(line.dropFirst(4)))
            }

            if !line.isEmpty || !fileHeader.isEmpty {
                fileHeader.append(line)
            }
        }

        finishFile()
        return files
    }

    private struct HunkHeader {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let section: String
    }

    private static func parseHunkHeader(_ line: String) throws -> HunkHeader {
        guard let closingRange = line.range(of: " @@", options: [], range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex) else {
            throw GitEngineError.invalidOutput("Invalid unified diff hunk header: \(line)")
        }

        let rangePart = String(line[line.index(line.startIndex, offsetBy: 3)..<closingRange.lowerBound])
        let section = String(line[closingRange.upperBound...])
        let pieces = rangePart.split(separator: " ")
        guard pieces.count == 2,
              pieces[0].hasPrefix("-"),
              pieces[1].hasPrefix("+") else {
            throw GitEngineError.invalidOutput("Invalid unified diff ranges: \(line)")
        }

        let oldRange = try parseRange(String(pieces[0].dropFirst()))
        let newRange = try parseRange(String(pieces[1].dropFirst()))
        return HunkHeader(
            oldStart: oldRange.start,
            oldCount: oldRange.count,
            newStart: newRange.start,
            newCount: newRange.count,
            section: section
        )
    }

    private static func parseRange(_ text: String) throws -> (start: Int, count: Int) {
        let parts = text.split(separator: ",", maxSplits: 1).map(String.init)
        guard let start = Int(parts[0]) else {
            throw GitEngineError.invalidOutput("Invalid unified diff range: \(text)")
        }
        let count: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]) else {
                throw GitEngineError.invalidOutput("Invalid unified diff count: \(text)")
            }
            count = parsed
        } else {
            count = 1
        }
        return (start, count)
    }

    private static func normalizeDiffPath(_ raw: String) -> String {
        if raw == "/dev/null" { return raw }
        if raw.hasPrefix("a/") || raw.hasPrefix("b/") {
            return String(raw.dropFirst(2))
        }
        return raw
    }
}

public enum GitPatchBuilder {
    public static func patch(for file: GitDiffFile, hunk: GitDiffHunk) -> String {
        makePatch(file: file, hunk: hunk, selectedChangedLineOrdinals: nil)
    }

    public static func patch(
        for file: GitDiffFile,
        hunk: GitDiffHunk,
        selectedChangedLineOrdinals: Set<Int>
    ) throws -> String {
        let validOrdinals = Set(hunk.lines.filter(\.isChange).map(\.ordinal))
        let selected = selectedChangedLineOrdinals.intersection(validOrdinals)
        guard !selected.isEmpty else {
            throw GitEngineError.invalidInput("Select at least one changed line.")
        }
        return makePatch(file: file, hunk: hunk, selectedChangedLineOrdinals: selected)
    }

    private static func makePatch(
        file: GitDiffFile,
        hunk: GitDiffHunk,
        selectedChangedLineOrdinals: Set<Int>?
    ) -> String {
        let emittedLines: [String]
        if let selectedChangedLineOrdinals {
            emittedLines = hunk.lines.compactMap { line in
                switch line.kind {
                case .context, .metadata:
                    return line.raw
                case .addition:
                    return selectedChangedLineOrdinals.contains(line.ordinal) ? line.raw : nil
                case .deletion:
                    if selectedChangedLineOrdinals.contains(line.ordinal) {
                        return line.raw
                    }
                    return " " + line.text
                }
            }
        } else {
            emittedLines = hunk.lines.map(\.raw)
        }

        let oldCount = emittedLines.count { $0.hasPrefix(" ") || $0.hasPrefix("-") }
        let newCount = emittedLines.count { $0.hasPrefix(" ") || $0.hasPrefix("+") }
        let oldRange = rangeText(start: hunk.oldStart, count: oldCount)
        let newRange = rangeText(start: hunk.newStart, count: newCount)
        let header = "@@ -\(oldRange) +\(newRange) @@\(hunk.section)"

        return (file.headerLines + [header] + emittedLines).joined(separator: "\n") + "\n"
    }

    private static func rangeText(start: Int, count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }
}

public extension GitService {
    func conflictFile(
        at repositoryURL: URL,
        path: String,
        maximumBytes: Int = 2 * 1024 * 1024
    ) async throws -> GitConflictFile {
        let root = try await repositoryRoot(for: repositoryURL)
        return try await Task.detached(priority: .userInitiated) {
            try SystemGitEngine().conflictFile(at: root, path: path, maximumBytes: maximumBytes)
        }.value
    }

    @discardableResult
    func resolveConflict(
        at repositoryURL: URL,
        path: String,
        result: String,
        maximumBytes: Int = 2 * 1024 * 1024
    ) async throws -> GitStatusSnapshot {
        let root = try await repositoryRoot(for: repositoryURL).standardizedFileURL
        let data = Data(result.utf8)
        let boundedMaximum = max(1, maximumBytes)
        guard data.count <= boundedMaximum else {
            throw GitConflictWorkspaceError.fileTooLarge(path)
        }
        guard !data.contains(0) else {
            throw GitConflictWorkspaceError.unsupportedBinary(path)
        }

        let resultURL = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard !path.isEmpty,
              path != ".",
              !path.hasPrefix("/"),
              !path.contains("\0"),
              resultURL.path.hasPrefix(rootPath) else {
            throw GitConflictWorkspaceError.invalidPath(path)
        }

        _ = try await conflictFile(at: root, path: path, maximumBytes: maximumBytes)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: resultURL.path)[.posixPermissions])
        try data.write(to: resultURL, options: [.atomic])
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: resultURL.path)
        }

        // Editing the working-tree document is a host-side document mutation. The Git index
        // mutation still goes through the existing service stage path, so coordinator,
        // checkpoints and operation journaling remain authoritative for Git state.
        try await stage(at: root, paths: [path])
        let load = try await loadRepository(at: root, includeMetadata: false, historyLimit: 1)
        guard !load.snapshot.paths.contains(where: { $0.path == path && $0.kind == .conflicted }) else {
            throw GitEngineError.invalidOutput("Git still reports \(path) as conflicted after staging the resolution.")
        }
        return load.snapshot
    }
}

// MARK: - Intelligent Git context boundary

public enum GitAIIntent: String, Codable, CaseIterable, Hashable, Sendable {
    case explainDiff
    case reviewChanges
    case composeCommitMessage
    case assistConflict
}

public struct GitAIContextPolicy: Codable, Hashable, Sendable {
    public let maximumCharacters: Int
    public let maximumPaths: Int
    public let maximumRecentCommits: Int
    public let sensitivePathFragments: [String]

    public init(
        maximumCharacters: Int = 120_000,
        maximumPaths: Int = 200,
        maximumRecentCommits: Int = 30,
        sensitivePathFragments: [String] = [
            ".env", "id_rsa", "id_ed25519", ".pem", ".p12", ".pfx", ".key",
            "credentials", "secrets", "secret.", "private_key", "auth-token", "access-token"
        ]
    ) {
        self.maximumCharacters = max(1_000, maximumCharacters)
        self.maximumPaths = max(1, maximumPaths)
        self.maximumRecentCommits = max(1, maximumRecentCommits)
        self.sensitivePathFragments = sensitivePathFragments
    }

    public func isSensitive(path: String) -> Bool {
        let normalized = path.lowercased()
        return sensitivePathFragments.contains { fragment in
            normalized.contains(fragment.lowercased())
        }
    }
}

public struct GitAIPathContext: Codable, Hashable, Sendable {
    public let path: String
    public let kind: GitStatusKind
    public let isStaged: Bool

    public init(path: String, kind: GitStatusKind, isStaged: Bool) {
        self.path = path
        self.kind = kind
        self.isStaged = isStaged
    }
}

public struct GitAICommitContext: Codable, Hashable, Sendable {
    public let hash: String
    public let subject: String
    public let author: String

    public init(hash: String, subject: String, author: String) {
        self.hash = hash
        self.subject = subject
        self.author = author
    }
}

public struct GitAIContext: Codable, Hashable, Sendable {
    public let repositoryName: String
    public let branch: String
    public let upstream: String?
    public let tracking: GitAheadBehind?
    public let operationMode: GitRepositoryOperationMode
    public let paths: [GitAIPathContext]
    public let unstagedDiff: String
    public let stagedDiff: String
    public let recentCommits: [GitAICommitContext]
    public let redactedPaths: [String]
    public let wasTruncated: Bool

    public init(
        repositoryName: String,
        branch: String,
        upstream: String?,
        tracking: GitAheadBehind?,
        operationMode: GitRepositoryOperationMode,
        paths: [GitAIPathContext],
        unstagedDiff: String,
        stagedDiff: String,
        recentCommits: [GitAICommitContext],
        redactedPaths: [String],
        wasTruncated: Bool
    ) {
        self.repositoryName = repositoryName
        self.branch = branch
        self.upstream = upstream
        self.tracking = tracking
        self.operationMode = operationMode
        self.paths = paths
        self.unstagedDiff = unstagedDiff
        self.stagedDiff = stagedDiff
        self.recentCommits = recentCommits
        self.redactedPaths = redactedPaths
        self.wasTruncated = wasTruncated
    }
}

public struct GitAIRequest: Codable, Hashable, Sendable {
    public let intent: GitAIIntent
    public let context: GitAIContext
    public let instruction: String?

    public init(intent: GitAIIntent, context: GitAIContext, instruction: String? = nil) {
        self.intent = intent
        self.context = context
        self.instruction = instruction
    }
}

public struct GitAIResponse: Codable, Hashable, Sendable {
    public let text: String
    public let provider: String
    public let model: String?

    public init(text: String, provider: String, model: String? = nil) {
        self.text = text
        self.provider = provider
        self.model = model
    }
}

public protocol GitAIProvider: Sendable {
    var providerName: String { get }
    func perform(_ request: GitAIRequest) async throws -> GitAIResponse
}

public enum GitAIContextBuilder {
    public static func build(
        repositoryURL: URL,
        snapshot: GitStatusSnapshot,
        intelligence: GitRepositoryIntelligence,
        unstagedDiff: String,
        stagedDiff: String,
        recentCommits: [GitCommit],
        policy: GitAIContextPolicy = GitAIContextPolicy()
    ) -> GitAIContext {
        let boundedStatuses = Array(snapshot.paths.prefix(policy.maximumPaths))
        let redactedPaths = boundedStatuses
            .map(\.path)
            .filter(policy.isSensitive(path:))
            .sorted()

        let safePaths = boundedStatuses
            .filter { !policy.isSensitive(path: $0.path) }
            .map { GitAIPathContext(path: $0.path, kind: $0.kind, isStaged: $0.isStaged) }

        let safeUnstaged = sanitizeDiff(unstagedDiff, policy: policy)
        let safeStaged = sanitizeDiff(stagedDiff, policy: policy)
        let combined = truncatePair(
            safeUnstaged,
            safeStaged,
            maximumCharacters: policy.maximumCharacters
        )
        let commits = recentCommits.prefix(policy.maximumRecentCommits).map {
            GitAICommitContext(hash: $0.hash, subject: $0.subject, author: $0.author)
        }

        return GitAIContext(
            repositoryName: repositoryURL.standardizedFileURL.lastPathComponent,
            branch: intelligence.branch,
            upstream: intelligence.upstream,
            tracking: intelligence.tracking,
            operationMode: intelligence.operationMode,
            paths: safePaths,
            unstagedDiff: combined.unstaged,
            stagedDiff: combined.staged,
            recentCommits: Array(commits),
            redactedPaths: redactedPaths,
            wasTruncated: snapshot.paths.count > policy.maximumPaths || combined.wasTruncated
        )
    }

    private static func sanitizeDiff(_ diff: String, policy: GitAIContextPolicy) -> String {
        guard !diff.isEmpty else { return "" }
        var output: [String] = []
        var block: [String] = []

        func flush() {
            guard !block.isEmpty else { return }
            let header = block.first ?? ""
            if policy.sensitivePathFragments.contains(where: { header.lowercased().contains($0.lowercased()) }) {
                output.append("diff --git [REDACTED] [REDACTED]\n[REDACTED SENSITIVE PATH]")
            } else {
                output.append(block.joined(separator: "\n"))
            }
            block.removeAll(keepingCapacity: true)
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flush()
            }
            block.append(line)
        }
        flush()
        return output.joined(separator: "\n")
    }

    private static func truncatePair(
        _ unstaged: String,
        _ staged: String,
        maximumCharacters: Int
    ) -> (unstaged: String, staged: String, wasTruncated: Bool) {
        let total = unstaged.count + staged.count
        guard total > maximumCharacters else { return (unstaged, staged, false) }

        let stagedBudget = min(staged.count, maximumCharacters / 2)
        let unstagedBudget = max(0, maximumCharacters - stagedBudget)
        let safeUnstaged = String(unstaged.prefix(unstagedBudget))
        let remaining = max(0, maximumCharacters - safeUnstaged.count)
        let safeStaged = String(staged.prefix(remaining))
        return (safeUnstaged, safeStaged, true)
    }
}

public enum GitAgentContextExporter {
    public static func markdown(_ context: GitAIContext) -> String {
        var lines: [String] = [
            "# Branchlight Agent Context",
            "",
            "Repository: \(context.repositoryName)",
            "Branch: \(context.branch)",
            "Upstream: \(context.upstream ?? "none")",
            "Tracking: \(context.tracking?.summary ?? "unknown")",
            "Operation: \(context.operationMode.rawValue)",
            "Truncated: \(context.wasTruncated ? "yes" : "no")",
            ""
        ]

        if !context.redactedPaths.isEmpty {
            lines += ["## Redacted sensitive paths"]
            lines += context.redactedPaths.map { "- \($0)" }
            lines.append("")
        }

        lines.append("## Changed paths")
        if context.paths.isEmpty {
            lines.append("- none")
        } else {
            lines += context.paths.map {
                "- \($0.kind.rawValue)\($0.isStaged ? " [staged]" : ""): \($0.path)"
            }
        }
        lines.append("")

        lines.append("## Recent commits")
        if context.recentCommits.isEmpty {
            lines.append("- none")
        } else {
            lines += context.recentCommits.map {
                "- \(String($0.hash.prefix(12))) \($0.subject) — \($0.author)"
            }
        }
        lines.append("")

        lines += ["## Unstaged diff", "```diff", context.unstagedDiff, "```", ""]
        lines += ["## Staged diff", "```diff", context.stagedDiff, "```", ""]
        return lines.joined(separator: "\n")
    }
}

public extension GitService {
    func intelligentContext(
        at repositoryURL: URL,
        policy: GitAIContextPolicy = GitAIContextPolicy()
    ) async throws -> GitAIContext {
        async let loadRequest = loadRepository(
            at: repositoryURL,
            includeMetadata: true,
            historyLimit: policy.maximumRecentCommits
        )
        async let intelligenceRequest = repositoryIntelligence(at: repositoryURL)
        async let unstagedRequest = diff(at: repositoryURL, paths: [], staged: false)
        async let stagedRequest = diff(at: repositoryURL, paths: [], staged: true)

        let (load, intelligence, unstaged, staged) = try await (
            loadRequest,
            intelligenceRequest,
            unstagedRequest,
            stagedRequest
        )
        return GitAIContextBuilder.build(
            repositoryURL: repositoryURL,
            snapshot: load.snapshot,
            intelligence: intelligence,
            unstagedDiff: unstaged,
            stagedDiff: staged,
            recentCommits: load.history ?? [],
            policy: policy
        )
    }

    func agentContextMarkdown(
        at repositoryURL: URL,
        policy: GitAIContextPolicy = GitAIContextPolicy()
    ) async throws -> String {
        GitAgentContextExporter.markdown(
            try await intelligentContext(at: repositoryURL, policy: policy)
        )
    }
}
