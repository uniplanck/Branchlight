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
