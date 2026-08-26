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
