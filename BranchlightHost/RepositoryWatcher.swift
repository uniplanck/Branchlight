import BranchlightCore
import CoreServices
import Foundation

final class RepositoryWatcher: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let queue = DispatchQueue(label: "com.uniplanck.branchlight.repository-watcher", qos: .utility)
    private let handler: Handler
    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?
    private var debounceItem: DispatchWorkItem?

    init(latency: CFTimeInterval = 0.35, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start(path: String) {
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            watcher.scheduleHandler()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        debounceItem?.cancel()
        debounceItem = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleHandler() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [handler] in
            handler()
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}

// MARK: - Local AI provider bridge

enum GitAILocalCommandError: LocalizedError, Sendable {
    case notConfigured
    case missingContext
    case invalidExecutable(String)
    case invalidArguments
    case timedOut
    case cancelled
    case failed(status: Int32, stderr: String)
    case outputTooLarge
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No local AI command provider is configured."
        case .missingContext:
            return "Refresh repository context before running the local AI provider."
        case .invalidExecutable(let path):
            return "The configured AI executable is not an absolute executable file: \(path)"
        case .invalidArguments:
            return "BRANCHLIGHT_AI_ARGUMENTS_JSON must be a JSON array of strings."
        case .timedOut:
            return "The local AI command exceeded its execution timeout."
        case .cancelled:
            return "The local AI command was cancelled."
        case .failed(let status, let stderr):
            return "The local AI command failed (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .outputTooLarge:
            return "The local AI command returned more output than Branchlight allows."
        case .emptyOutput:
            return "The local AI command returned no response."
        }
    }
}

struct GitAILocalCommandConfiguration: Sendable, Hashable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
    let maximumOutputBytes: Int

    init(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 90,
        maximumOutputBytes: Int = 1_048_576
    ) throws {
        let standardized = executableURL.standardizedFileURL
        guard standardized.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: standardized.path) else {
            throw GitAILocalCommandError.invalidExecutable(executableURL.path)
        }
        self.executableURL = standardized
        self.arguments = arguments
        self.timeout = min(max(timeout, 1), 600)
        self.maximumOutputBytes = min(max(maximumOutputBytes, 1_024), 8 * 1_048_576)
    }

    static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GitAILocalCommandConfiguration {
        guard let rawPath = environment["BRANCHLIGHT_AI_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw GitAILocalCommandError.notConfigured
        }

        let arguments: [String]
        if let rawArguments = environment["BRANCHLIGHT_AI_ARGUMENTS_JSON"], !rawArguments.isEmpty {
            guard let data = rawArguments.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                throw GitAILocalCommandError.invalidArguments
            }
            arguments = decoded
        } else {
            arguments = []
        }

        let timeout = environment["BRANCHLIGHT_AI_TIMEOUT_SECONDS"].flatMap(TimeInterval.init) ?? 90
        return try GitAILocalCommandConfiguration(
            executableURL: URL(fileURLWithPath: rawPath),
            arguments: arguments,
            timeout: timeout
        )
    }
}

struct GitAILocalCommandProvider: GitAIProvider, Sendable {
    let configuration: GitAILocalCommandConfiguration

    var providerName: String {
        "local-command:\(configuration.executableURL.lastPathComponent)"
    }

    init(configuration: GitAILocalCommandConfiguration) {
        self.configuration = configuration
    }

    func perform(_ request: GitAIRequest) async throws -> GitAIResponse {
        let prompt = GitAIPromptBuilder.prompt(for: request)
        let configuration = configuration
        let providerName = providerName

        return try await Task.detached(priority: .userInitiated) {
            let result = try Self.run(prompt: prompt, configuration: configuration)
            return GitAIResponse(text: result, provider: providerName, model: nil)
        }.value
    }

    private static func run(
        prompt: String,
        configuration: GitAILocalCommandConfiguration
    ) throws -> String {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        if let path = inherited["PATH"] { environment["PATH"] = path }
        if let home = inherited["HOME"] { environment["HOME"] = home }
        if let lang = inherited["LANG"] { environment["LANG"] = lang }
        environment["TERM"] = "dumb"
        process.environment = environment

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(configuration.timeout)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw GitAILocalCommandError.cancelled
            }
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw GitAILocalCommandError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard stdout.count <= configuration.maximumOutputBytes else {
            throw GitAILocalCommandError.outputTooLarge
        }
        guard process.terminationStatus == 0 else {
            throw GitAILocalCommandError.failed(
                status: process.terminationStatus,
                stderr: String(data: stderr, encoding: .utf8) ?? ""
            )
        }

        let response = (String(data: stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else { throw GitAILocalCommandError.emptyOutput }
        return response
    }
}

@MainActor
extension GitAIWorkbenchModel {
    var hasConfiguredLocalProvider: Bool {
        (try? GitAILocalCommandConfiguration.fromEnvironment()) != nil
    }

    var configuredLocalProviderName: String? {
        guard let configuration = try? GitAILocalCommandConfiguration.fromEnvironment() else { return nil }
        return GitAILocalCommandProvider(configuration: configuration).providerName
    }

    func performConfiguredLocalProvider() async throws -> GitAIResponse {
        guard let context else { throw GitAILocalCommandError.missingContext }
        let configuration = try GitAILocalCommandConfiguration.fromEnvironment()
        let provider = GitAILocalCommandProvider(configuration: configuration)
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await provider.perform(
            GitAIRequest(
                intent: intent,
                context: context,
                instruction: trimmed.isEmpty ? nil : trimmed
            )
        )
    }
}
