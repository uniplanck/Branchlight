import BranchlightCore
import Foundation
import Security

enum HostFinderRequest: Sendable {
    case intent(FinderIntent)
    case openPath(String)
}

actor HostStatusCache {
    private let cache: SharedStatusCache?
    private let intelligenceResolver: XPCRepositoryResolver

    init(
        cache: SharedStatusCache? = SharedStatusCache(),
        intelligenceService: any GitService = InProcessGitService()
    ) {
        self.cache = cache
        self.intelligenceResolver = XPCRepositoryResolver(fallback: intelligenceService)
    }

    func load() -> StatusCacheEnvelope {
        cache?.load() ?? StatusCacheEnvelope()
    }

    func replaceSnapshot(_ snapshot: GitStatusSnapshot) async throws -> StatusCacheEnvelope? {
        guard let cache else { return nil }
        let repositoryURL = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
        let intelligence = try await intelligenceResolver.repositoryIntelligence(at: repositoryURL)
        return try cache.replaceRepositoryState(snapshot: snapshot, intelligence: intelligence)
    }
}

actor HostFinderRequestCache {
    private let cache: SharedStatusCache?

    init(cache: SharedStatusCache? = SharedStatusCache()) {
        self.cache = cache
    }

    func consumeFinderRequest() -> HostFinderRequest? {
        if let intent = cache?.consumePendingFinderIntent() {
            return .intent(intent)
        }
        if let path = cache?.consumePendingOpenPath() {
            return .openPath(path)
        }
        return nil
    }
}

// MARK: - Host-only GitHub credential boundary

enum GitHubIntegrationError: LocalizedError, Sendable {
    case keychain(OSStatus)
    case invalidResponse
    case http(status: Int, message: String)
    case unsupportedRepository
    case oauthClientNotConfigured
    case oauthDenied(String)
    case oauthExpired

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "GitHub credential Keychain operation failed (\(status))."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .http(let status, let message):
            return "GitHub request failed (HTTP \(status)): \(message)"
        case .unsupportedRepository:
            return "The selected remote is not a supported GitHub repository."
        case .oauthClientNotConfigured:
            return "Branchlight GitHub OAuth client ID is not configured."
        case .oauthDenied(let message):
            return message
        case .oauthExpired:
            return "GitHub device authorization expired before it was completed."
        }
    }
}

struct GitHubCredentialStore: Sendable {
    private let service = "com.uniplanck.Branchlight.github"
    private let account = "oauth-token"

    func loadToken() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GitHubIntegrationError.keychain(status) }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw GitHubIntegrationError.invalidResponse
        }
        return token
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubIntegrationError.invalidResponse }
        let data = Data(trimmed.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GitHubIntegrationError.keychain(updateStatus)
        }

        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw GitHubIntegrationError.keychain(addStatus) }
    }

    func deleteToken() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubIntegrationError.keychain(status)
        }
    }
}

struct GitHubOAuthConfiguration: Sendable {
    let clientID: String

    static func fromMainBundle() throws -> GitHubOAuthConfiguration {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "BranchlightGitHubClientID") as? String else {
            throw GitHubIntegrationError.oauthClientNotConfigured
        }
        let clientID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw GitHubIntegrationError.oauthClientNotConfigured }
        return GitHubOAuthConfiguration(clientID: clientID)
    }
}

struct GitHubDeviceAuthorization: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

actor GitHubDeviceFlowClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start(clientID: String, scope: String = "repo read:user") async throws -> GitHubDeviceAuthorization {
        let response: DeviceCodeResponse = try await formRequest(
            url: URL(string: "https://github.com/login/device/code")!,
            values: ["client_id": clientID, "scope": scope]
        )
        guard let verificationURL = URL(string: response.verificationURI) else {
            throw GitHubIntegrationError.invalidResponse
        }
        return GitHubDeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: verificationURL,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            interval: TimeInterval(max(response.interval ?? 5, 1))
        )
    }

    func waitForToken(clientID: String, authorization: GitHubDeviceAuthorization) async throws -> String {
        var interval = authorization.interval
        while Date() < authorization.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            let response: TokenResponse = try await formRequest(
                url: URL(string: "https://github.com/login/oauth/access_token")!,
                values: [
                    "client_id": clientID,
                    "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ]
            )

            if let token = response.accessToken, !token.isEmpty { return token }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw GitHubIntegrationError.oauthExpired
            case "access_denied":
                throw GitHubIntegrationError.oauthDenied(response.errorDescription ?? "GitHub authorization was denied.")
            case .some(let value):
                throw GitHubIntegrationError.oauthDenied(response.errorDescription ?? value)
            case .none:
                throw GitHubIntegrationError.invalidResponse
            }
        }
        throw GitHubIntegrationError.oauthExpired
    }

    private func formRequest<Response: Decodable>(
        url: URL,
        values: [String: String]
    ) async throws -> Response {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw GitHubIntegrationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Branchlight/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubIntegrationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubIntegrationError.http(
                status: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
        }
    }
}

actor GitHubAuthenticationController {
    private let credentials: GitHubCredentialStore
    private let deviceFlow: GitHubDeviceFlowClient

    init(
        credentials: GitHubCredentialStore = GitHubCredentialStore(),
        deviceFlow: GitHubDeviceFlowClient = GitHubDeviceFlowClient()
    ) {
        self.credentials = credentials
        self.deviceFlow = deviceFlow
    }

    func begin() async throws -> (GitHubOAuthConfiguration, GitHubDeviceAuthorization) {
        let configuration = try GitHubOAuthConfiguration.fromMainBundle()
        let authorization = try await deviceFlow.start(clientID: configuration.clientID)
        return (configuration, authorization)
    }

    func complete(
        configuration: GitHubOAuthConfiguration,
        authorization: GitHubDeviceAuthorization
    ) async throws {
        let token = try await deviceFlow.waitForToken(
            clientID: configuration.clientID,
            authorization: authorization
        )
        try credentials.saveToken(token)
    }

    func disconnect() throws {
        try credentials.deleteToken()
    }

    func isConnected() -> Bool {
        (try? credentials.loadToken()) != nil
    }
}

// MARK: - GitHub RemoteProvider implementation

actor GitHubProvider: RemoteProvider {
    nonisolated let kind: GitRemoteProviderKind = .github

    private let credentials: GitHubCredentialStore
    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        credentials: GitHubCredentialStore = GitHubCredentialStore(),
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func repositorySummary(for repository: GitRemoteRepository) async throws -> RemoteRepositorySummary {
        let payload: RepositoryPayload = try await get(repository, suffix: "")
        return RemoteRepositorySummary(
            fullName: payload.fullName,
            defaultBranch: payload.defaultBranch,
            isPrivate: payload.isPrivate,
            webURL: payload.htmlURL
        )
    }

    func pullRequests(
        for repository: GitRemoteRepository,
        state: RemotePullRequestState
    ) async throws -> [RemotePullRequest] {
        let payload: [PullRequestPayload] = try await get(
            repository,
            suffix: "/pulls",
            queryItems: [
                URLQueryItem(name: "state", value: state.rawValue),
                URLQueryItem(name: "per_page", value: "50")
            ]
        )
        return payload.map {
            RemotePullRequest(
                number: $0.number,
                title: $0.title,
                author: $0.user.login,
                headBranch: $0.head.ref,
                baseBranch: $0.base.ref,
                isDraft: $0.draft ?? false,
                state: RemotePullRequestState(rawValue: $0.state) ?? state,
                webURL: $0.htmlURL
            )
        }
    }

    func checkRuns(for repository: GitRemoteRepository, ref: String) async throws -> [RemoteCheckRun] {
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        let payload: CheckRunsPayload = try await get(
            repository,
            suffix: "/commits/\(encodedRef)/check-runs"
        )
        return payload.checkRuns.map {
            RemoteCheckRun(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                conclusion: $0.conclusion,
                detailsURL: $0.detailsURL
            )
        }
    }

    func reviews(for repository: GitRemoteRepository, pullRequestNumber: Int) async throws -> [RemoteReview] {
        guard pullRequestNumber > 0 else { throw GitHubIntegrationError.invalidResponse }
        let payload: [ReviewPayload] = try await get(
            repository,
            suffix: "/pulls/\(pullRequestNumber)/reviews"
        )
        return payload.map {
            RemoteReview(
                id: $0.id,
                author: $0.user.login,
                state: $0.state,
                submittedAt: $0.submittedAt,
                body: $0.body
            )
        }
    }

    private func get<Response: Decodable>(
        _ repository: GitRemoteRepository,
        suffix: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        guard repository.provider == .github,
              repository.host == "github.com" || repository.host == "www.github.com",
              !repository.owner.contains("/") else {
            throw GitHubIntegrationError.unsupportedRepository
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository.owner)/\(repository.name)\(suffix)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw GitHubIntegrationError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Branchlight/0.1", forHTTPHeaderField: "User-Agent")
        if let token = try credentials.loadToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubIntegrationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
            throw GitHubIntegrationError.http(
                status: http.statusCode,
                message: apiError?.message ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }
        return try decoder.decode(Response.self, from: data)
    }

    private struct RepositoryPayload: Decodable {
        let fullName: String
        let defaultBranch: String
        let isPrivate: Bool
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case defaultBranch = "default_branch"
            case isPrivate = "private"
            case htmlURL = "html_url"
        }
    }

    private struct PullRequestPayload: Decodable {
        let number: Int
        let title: String
        let user: UserPayload
        let head: BranchPayload
        let base: BranchPayload
        let draft: Bool?
        let state: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case number, title, user, head, base, draft, state
            case htmlURL = "html_url"
        }
    }

    private struct UserPayload: Decodable { let login: String }
    private struct BranchPayload: Decodable { let ref: String }

    private struct CheckRunsPayload: Decodable {
        let checkRuns: [CheckRunPayload]
        enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
    }

    private struct CheckRunPayload: Decodable {
        let id: Int64
        let name: String
        let status: String
        let conclusion: String?
        let detailsURL: String?

        enum CodingKeys: String, CodingKey {
            case id, name, status, conclusion
            case detailsURL = "details_url"
        }
    }

    private struct ReviewPayload: Decodable {
        let id: Int64
        let user: UserPayload
        let state: String
        let submittedAt: Date?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case id, user, state, body
            case submittedAt = "submitted_at"
        }
    }

    private struct APIErrorPayload: Decodable { let message: String }
}
