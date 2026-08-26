import AppKit
import BranchlightCore
import Combine
import SwiftUI

final class BranchlightAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        sender.windows
            .first(where: { $0.canBecomeMain || $0.canBecomeKey })?
            .makeKeyAndOrderFront(nil)
        return true
    }
}

@main
struct BranchlightApp: App {
    @NSApplicationDelegateAdaptor(BranchlightAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var githubModel = GitHubPanelModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(githubModel)
                .frame(minWidth: 720, minHeight: 500)
                .onAppear {
                    model.consumeFinderRequest()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.consumeFinderRequest()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            BranchlightCommands(model: model)
        }

        Window("GitHub Live", id: "github-live") {
            GitHubLiveView()
                .environmentObject(model)
                .environmentObject(githubModel)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 900, height: 680)
    }
}

struct BranchlightCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Branchlight") {
            Button("GitHub Live") {
                openWindow(id: "github-live")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("Copy Agent Context") {
                Task { @MainActor in
                    guard let repositoryURL = model.repositoryURL else { return }
                    do {
                        let context = try await InProcessGitService().agentContextMarkdown(at: repositoryURL)
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(context, forType: .string)
                        model.errorMessage = nil
                        model.lastOperation = "Agent context copied"
                    } catch {
                        model.errorMessage = "Agent context export failed: \(error.localizedDescription)"
                    }
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model.repositoryURL == nil)
        }
    }
}

@MainActor
final class GitHubPanelModel: ObservableObject {
    @Published private(set) var remoteRepository: GitRemoteRepository?
    @Published private(set) var repositorySummary: RemoteRepositorySummary?
    @Published private(set) var pullRequests: [RemotePullRequest] = []
    @Published private(set) var checkRuns: [RemoteCheckRun] = []
    @Published private(set) var reviews: [RemoteReview] = []
    @Published private(set) var reviewedPullRequestNumber: Int?
    @Published private(set) var deviceAuthorization: GitHubDeviceAuthorization?
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let discovery: GitRemoteDiscovery
    private let provider: any RemoteProvider
    private let authentication: GitHubAuthenticationController
    private var authenticationTask: Task<Void, Never>?

    init(
        discovery: GitRemoteDiscovery = GitRemoteDiscovery(),
        provider: any RemoteProvider = GitHubProvider(),
        authentication: GitHubAuthenticationController = GitHubAuthenticationController()
    ) {
        self.discovery = discovery
        self.provider = provider
        self.authentication = authentication
        Task { [weak self] in
            guard let self else { return }
            self.isConnected = await authentication.isConnected()
        }
    }

    deinit {
        authenticationTask?.cancel()
    }

    func refresh(repositoryURL: URL?, ref: String?) async {
        guard let repositoryURL else {
            clearRepositoryState()
            return
        }

        isLoading = true
        errorMessage = nil
        isConnected = await authentication.isConnected()

        do {
            guard let remote = try await discovery.origin(at: repositoryURL) else {
                clearRemoteData()
                errorMessage = "This repository has no origin remote."
                isLoading = false
                return
            }
            remoteRepository = remote

            guard remote.provider == .github else {
                repositorySummary = nil
                pullRequests = []
                checkRuns = []
                reviews = []
                reviewedPullRequestNumber = nil
                errorMessage = "The origin remote is not a GitHub repository."
                isLoading = false
                return
            }

            async let summaryRequest = provider.repositorySummary(for: remote)
            async let pullRequestRequest = provider.pullRequests(for: remote, state: .open)

            let summary = try await summaryRequest
            let pullRequests = try await pullRequestRequest
            let checks: [RemoteCheckRun]
            if let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
                checks = try await provider.checkRuns(for: remote, ref: ref)
            } else {
                checks = []
            }

            repositorySummary = summary
            self.pullRequests = pullRequests
            checkRuns = checks
            reviews = []
            reviewedPullRequestNumber = nil
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func loadReviews(for pullRequestNumber: Int) async {
        guard let remoteRepository, remoteRepository.provider == .github else { return }
        isLoading = true
        errorMessage = nil
        do {
            reviews = try await provider.reviews(
                for: remoteRepository,
                pullRequestNumber: pullRequestNumber
            )
            reviewedPullRequestNumber = pullRequestNumber
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func beginAuthentication() async {
        authenticationTask?.cancel()
        isLoading = true
        errorMessage = nil

        do {
            let (configuration, authorization) = try await authentication.begin()
            deviceAuthorization = authorization
            isLoading = false

            authenticationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await authentication.complete(
                        configuration: configuration,
                        authorization: authorization
                    )
                    self.isConnected = true
                    self.deviceAuthorization = nil
                    self.errorMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.deviceAuthorization = nil
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func disconnect() async {
        authenticationTask?.cancel()
        authenticationTask = nil
        do {
            try await authentication.disconnect()
            isConnected = false
            deviceAuthorization = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearRepositoryState() {
        remoteRepository = nil
        clearRemoteData()
        errorMessage = nil
        isLoading = false
    }

    private func clearRemoteData() {
        repositorySummary = nil
        pullRequests = []
        checkRuns = []
        reviews = []
        reviewedPullRequestNumber = nil
    }
}

struct GitHubLiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var github: GitHubPanelModel
    @State private var selectedPullRequestNumber: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let authorization = github.deviceAuthorization {
                deviceAuthorizationCard(authorization)
            }

            if let error = github.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let summary = github.repositorySummary {
                repositoryCard(summary)
            }

            HSplitView {
                pullRequestsPane
                    .frame(minWidth: 320)
                detailPane
                    .frame(minWidth: 360)
            }
        }
        .padding(18)
        .task {
            await refresh()
        }
        .onChange(of: model.repositoryURL) { _ in
            Task { await refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GitHub Live")
                    .font(.title2.weight(.semibold))
                Text(github.remoteRepository?.fullName ?? "Remote repository intelligence")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if github.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Button("Disconnect") {
                    Task { await github.disconnect() }
                }
            } else {
                Button("Connect GitHub…") {
                    Task { await github.beginAuthentication() }
                }
            }

            Button {
                Task { await refresh() }
            } label: {
                if github.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(github.isLoading || model.repositoryURL == nil)
        }
    }

    private func deviceAuthorizationCard(_ authorization: GitHubDeviceAuthorization) -> some View {
        GroupBox("GitHub Device Authorization") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter this code on GitHub")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(authorization.userCode)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
                Spacer()
                Link("Open GitHub", destination: authorization.verificationURL)
            }
            .padding(.vertical, 4)
        }
    }

    private func repositoryCard(_ summary: RemoteRepositorySummary) -> some View {
        GroupBox {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.fullName)
                        .font(.headline)
                    Text("Default branch: \(summary.defaultBranch)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary.isPrivate ? "Private" : "Public")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let url = URL(string: summary.webURL) {
                    Link("Open Repository", destination: url)
                }
            }
        }
    }

    private var pullRequestsPane: some View {
        GroupBox("Open Pull Requests (\(github.pullRequests.count))") {
            if github.pullRequests.isEmpty {
                Text("No open pull requests")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(github.pullRequests) { pullRequest in
                    Button {
                        selectedPullRequestNumber = pullRequest.number
                        Task { await github.loadReviews(for: pullRequest.number) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("#\(pullRequest.number)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(pullRequest.title)
                                    .lineLimit(1)
                                if pullRequest.isDraft {
                                    Text("Draft")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("\(pullRequest.headBranch) → \(pullRequest.baseBranch) · \(pullRequest.author)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Checks for current branch") {
                if github.checkRuns.isEmpty {
                    Text("No check runs found")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(github.checkRuns) { check in
                            HStack {
                                Image(systemName: checkSymbol(check))
                                Text(check.name)
                                Spacer()
                                Text(check.conclusion ?? check.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            GroupBox(selectedPullRequestNumber.map { "Reviews for #\($0)" } ?? "Reviews") {
                if let selectedPullRequestNumber,
                   let pullRequest = github.pullRequests.first(where: { $0.number == selectedPullRequestNumber }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pullRequest.title)
                            .font(.headline)
                        if let url = URL(string: pullRequest.webURL) {
                            Link("Open Pull Request", destination: url)
                        }
                        Divider()
                        if github.reviewedPullRequestNumber != selectedPullRequestNumber {
                            ProgressView()
                                .controlSize(.small)
                        } else if github.reviews.isEmpty {
                            Text("No submitted reviews")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(github.reviews) { review in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(review.author) · \(review.state)")
                                        .font(.callout.weight(.medium))
                                    if let body = review.body, !body.isEmpty {
                                        Text(body)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("Select a pull request to inspect reviews.")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private func refresh() async {
        await github.refresh(
            repositoryURL: model.repositoryURL,
            ref: model.snapshot?.branch
        )
        if let selectedPullRequestNumber,
           github.pullRequests.contains(where: { $0.number == selectedPullRequestNumber }) {
            await github.loadReviews(for: selectedPullRequestNumber)
        } else {
            selectedPullRequestNumber = nil
        }
    }

    private func checkSymbol(_ check: RemoteCheckRun) -> String {
        switch check.conclusion?.lowercased() {
        case "success": return "checkmark.circle.fill"
        case "failure", "cancelled", "timed_out": return "xmark.circle.fill"
        case nil: return "clock"
        default: return "circle"
        }
    }
}
