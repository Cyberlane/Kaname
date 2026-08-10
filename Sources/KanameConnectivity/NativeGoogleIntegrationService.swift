@preconcurrency import Foundation
import CryptoKit
import Security
#if os(macOS)
import AppKit
@preconcurrency import Network
#endif

public struct NativeGoogleAccountSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let identity: String
    public let displayName: String
    public let capabilities: [String]

}

public struct GoogleOAuthClientConfiguration: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String?
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    public static func decode(downloadedJSON data: Data) throws -> Self {
        struct Envelope: Decodable {
            struct Installed: Decodable {
                let clientID: String
                let clientSecret: String?
                let authURI: URL
                let tokenURI: URL

                enum CodingKeys: String, CodingKey {
                    case clientID = "client_id"
                    case clientSecret = "client_secret"
                    case authURI = "auth_uri"
                    case tokenURI = "token_uri"
                }
            }
            let installed: Installed
        }

        do {
            let decoded = try JSONDecoder().decode(Envelope.self, from: data).installed
            guard !decoded.clientID.isEmpty,
                  decoded.authURI.host == "accounts.google.com",
                  decoded.tokenURI.host == "oauth2.googleapis.com" else {
                throw NativeGoogleIntegrationError.invalidClientConfiguration
            }
            return Self(
                clientID: decoded.clientID,
                clientSecret: decoded.clientSecret,
                authorizationEndpoint: decoded.authURI,
                tokenEndpoint: decoded.tokenURI
            )
        } catch let error as NativeGoogleIntegrationError {
            throw error
        } catch {
            throw NativeGoogleIntegrationError.invalidClientConfiguration
        }
    }
}

public enum NativeGoogleIntegrationError: Error, Equatable, LocalizedError, Sendable {
    case clientConfigurationMissing
    case invalidClientConfiguration
    case authorizationUnavailable
    case authorizationCancelled
    case invalidAuthorizationCallback
    case tokenUnavailable(String)
    case keychainFailure(Int32)
    case invalidResponse(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .clientConfigurationMissing:
            "Import a Google OAuth desktop client JSON file before adding an account."
        case .invalidClientConfiguration:
            "That file is not a valid Google OAuth desktop client configuration."
        case .authorizationUnavailable:
            "Kaname could not start the private local Google authorization callback."
        case .authorizationCancelled:
            "Google account authorization was cancelled."
        case .invalidAuthorizationCallback:
            "Google returned an invalid authorization response."
        case let .tokenUnavailable(identity):
            "The secure Google session for \(identity) is unavailable. Reconnect that account."
        case .keychainFailure:
            "Kaname could not access its secure Google account storage."
        case let .invalidResponse(service):
            "\(service) returned an unsupported response."
        case let .requestFailed(service):
            "\(service) could not complete the request."
        }
    }
}

public struct GoogleAuthorizationRequest: Equatable, Sendable {
    public let url: URL
    public let redirectURI: URL
    public let verifier: String
    public let state: String
}

public enum GoogleOAuthRequestBuilder {
    public static let scopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
    ]

    public static func make(
        configuration: GoogleOAuthClientConfiguration,
        redirectURI: URL,
        verifier: String = randomURLSafeString(byteCount: 48),
        state: String = randomURLSafeString(byteCount: 32)
    ) throws -> GoogleAuthorizationRequest {
        guard verifier.count >= 43, state.count >= 32 else {
            throw NativeGoogleIntegrationError.authorizationUnavailable
        }
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw NativeGoogleIntegrationError.authorizationUnavailable
        }
        return GoogleAuthorizationRequest(url: url, redirectURI: redirectURI, verifier: verifier, state: state)
    }

    public static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes).base64URLEncodedString()
    }
}

private struct GoogleTokenRecord: Codable, Sendable {
    var accessToken: String
    let refreshToken: String
    var expiresAt: Date
}

private struct GoogleAccountIndex: Codable {
    var accounts: [NativeGoogleAccountSnapshot]
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Double
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct GoogleUserInfo: Decodable {
    let subject: String
    let email: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case email
        case name
    }
}

public actor NativeGoogleIntegrationService {
    private let rootDirectory: URL
    private let session: URLSession
    private let keychainService: String

    public init(
        rootDirectory: URL? = nil,
        session: URLSession = .shared,
        keychainService: String = "com.cyberlane.kaname.desktop.google-oauth"
    ) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.rootDirectory = rootDirectory ?? applicationSupport.appending(path: "Kaname/Google", directoryHint: .isDirectory)
        self.session = session
        self.keychainService = keychainService
    }

    public var hasClientConfiguration: Bool {
        FileManager.default.fileExists(atPath: clientConfigurationURL.path)
    }

    public func importClientConfiguration(from sourceURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        _ = try GoogleOAuthClientConfiguration.decode(downloadedJSON: data)
        try ensurePrivateDirectory()
        try data.write(to: clientConfigurationURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clientConfigurationURL.path)
    }

    public func accounts() throws -> [NativeGoogleAccountSnapshot] {
        guard FileManager.default.fileExists(atPath: accountIndexURL.path) else { return [] }
        let data = try Data(contentsOf: accountIndexURL)
        return try JSONDecoder().decode(GoogleAccountIndex.self, from: data).accounts
    }

#if os(macOS)
    public func connectAccount() async throws -> NativeGoogleAccountSnapshot {
        let configuration = try loadClientConfiguration()
        let receiver = try await GoogleLoopbackReceiver.start()
        let request = try GoogleOAuthRequestBuilder.make(
            configuration: configuration,
            redirectURI: receiver.redirectURI
        )
        guard NSWorkspace.shared.open(request.url) else {
            receiver.cancel()
            throw NativeGoogleIntegrationError.authorizationUnavailable
        }
        let code = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await receiver.waitForCode(expectedState: request.state) }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw NativeGoogleIntegrationError.authorizationCancelled
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NativeGoogleIntegrationError.authorizationCancelled
            }
            return result
        }
        let token = try await exchangeCode(code, request: request, configuration: configuration)
        let user = try await fetchUserInfo(accessToken: token.accessToken)
        guard !user.subject.isEmpty, !user.email.isEmpty, let refreshToken = token.refreshToken else {
            throw NativeGoogleIntegrationError.invalidResponse("Google OAuth")
        }
        let account = NativeGoogleAccountSnapshot(
            id: user.subject,
            identity: user.email,
            displayName: user.name ?? user.email,
            capabilities: ["Gmail", "Google Calendar"]
        )
        try storeToken(
            GoogleTokenRecord(
                accessToken: token.accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(token.expiresIn)
            ),
            accountID: account.id
        )
        try upsertAccount(account)
        return account
    }
#endif

    public func listCalendars(accountIDs: [String]? = nil) async throws -> [PersonalCalendarSourceSnapshot] {
        let selected = try selectedAccounts(accountIDs)
        var snapshots: [PersonalCalendarSourceSnapshot] = []
        for account in selected {
            let accessToken = try await validAccessToken(for: account)
            var pageToken: String?
            for _ in 0..<20 {
                var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
                components.queryItems = [URLQueryItem(name: "maxResults", value: "250")]
                if let pageToken {
                    components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
                }
                let data = try await authorizedData(url: components.url!, accessToken: accessToken, service: "Google Calendar")
                let page = try GoogleAPIResponseParser.calendarPage(data: data, account: account)
                snapshots.append(contentsOf: page.calendars)
                pageToken = page.nextPageToken
                if pageToken == nil { break }
            }
        }
        return snapshots
    }

    public func listInbox(accountIDs: [String]? = nil, limit: Int = 40) async throws -> [PersonalMailThreadSnapshot] {
        let selected = try selectedAccounts(accountIDs)
        let boundedLimit = min(max(limit, 1), 100)
        var snapshots: [PersonalMailThreadSnapshot] = []
        for account in selected {
            let accessToken = try await validAccessToken(for: account)
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!
            components.queryItems = [
                URLQueryItem(name: "labelIds", value: "INBOX"),
                URLQueryItem(name: "maxResults", value: "\(boundedLimit)"),
            ]
            let data = try await authorizedData(url: components.url!, accessToken: accessToken, service: "Gmail")
            let references = try GoogleAPIResponseParser.threadReferences(data: data)
            for reference in references {
                var detail = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(reference)")!
                detail.queryItems = [
                    URLQueryItem(name: "format", value: "metadata"),
                    URLQueryItem(name: "metadataHeaders", value: "From"),
                    URLQueryItem(name: "metadataHeaders", value: "Subject"),
                    URLQueryItem(name: "metadataHeaders", value: "Date"),
                ]
                let threadData = try await authorizedData(url: detail.url!, accessToken: accessToken, service: "Gmail")
                snapshots.append(try GoogleAPIResponseParser.thread(data: threadData, account: account))
            }
        }
        return snapshots
    }

    public func disconnect(accountID: String) throws {
        try removeToken(accountID: accountID)
        var current = try accounts()
        current.removeAll { $0.id == accountID }
        try writeAccountIndex(current)
    }

    private func selectedAccounts(_ accountIDs: [String]?) throws -> [NativeGoogleAccountSnapshot] {
        let all = try accounts()
        guard let accountIDs else { return all }
        let selected = Set(accountIDs)
        return all.filter { selected.contains($0.id) }
    }

    private func loadClientConfiguration() throws -> GoogleOAuthClientConfiguration {
        guard let data = try? Data(contentsOf: clientConfigurationURL) else {
            throw NativeGoogleIntegrationError.clientConfigurationMissing
        }
        return try GoogleOAuthClientConfiguration.decode(downloadedJSON: data)
    }

    private func exchangeCode(
        _ code: String,
        request: GoogleAuthorizationRequest,
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> GoogleTokenResponse {
        var fields = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": request.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": request.redirectURI.absoluteString,
        ]
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        return try await tokenRequest(configuration: configuration, fields: fields)
    }

    private func refreshToken(_ record: GoogleTokenRecord, configuration: GoogleOAuthClientConfiguration) async throws -> GoogleTokenRecord {
        var fields = [
            "client_id": configuration.clientID,
            "refresh_token": record.refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        let response = try await tokenRequest(configuration: configuration, fields: fields)
        return GoogleTokenRecord(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? record.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn)
        )
    }

    private func tokenRequest(
        configuration: GoogleOAuthClientConfiguration,
        fields: [String: String]
    ) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key.formURLEncoded)=\($0.value.formURLEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let data = try await responseData(for: request, service: "Google OAuth")
        do { return try JSONDecoder().decode(GoogleTokenResponse.self, from: data) }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Google OAuth") }
    }

    private func fetchUserInfo(accessToken: String) async throws -> GoogleUserInfo {
        let url = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!
        let data = try await authorizedData(url: url, accessToken: accessToken, service: "Google identity")
        do { return try JSONDecoder().decode(GoogleUserInfo.self, from: data) }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Google identity") }
    }

    private func authorizedData(url: URL, accessToken: String, service: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await responseData(for: request, service: service)
    }

    private func responseData(for request: URLRequest, service: String) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw NativeGoogleIntegrationError.requestFailed(service)
            }
            return data
        } catch let error as NativeGoogleIntegrationError {
            throw error
        } catch {
            throw NativeGoogleIntegrationError.requestFailed(service)
        }
    }

    private func validAccessToken(for account: NativeGoogleAccountSnapshot) async throws -> String {
        var record = try loadToken(accountID: account.id, identity: account.identity)
        if record.expiresAt.timeIntervalSinceNow < 60 {
            record = try await refreshToken(record, configuration: loadClientConfiguration())
            try storeToken(record, accountID: account.id)
        }
        return record.accessToken
    }

    private func upsertAccount(_ account: NativeGoogleAccountSnapshot) throws {
        var current = try accounts()
        current.removeAll { $0.id == account.id }
        current.append(account)
        try writeAccountIndex(current.sorted { $0.identity.localizedCaseInsensitiveCompare($1.identity) == .orderedAscending })
    }

    private func writeAccountIndex(_ accounts: [NativeGoogleAccountSnapshot]) throws {
        try ensurePrivateDirectory()
        let data = try JSONEncoder().encode(GoogleAccountIndex(accounts: accounts))
        try data.write(to: accountIndexURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountIndexURL.path)
    }

    private func ensurePrivateDirectory() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
    }

    private func storeToken(_ token: GoogleTokenRecord, accountID: String) throws {
        let data = try JSONEncoder().encode(token)
        let lookup = keychainLookup(accountID: accountID)
        let update = [kSecValueData: data] as CFDictionary
        let updated = SecItemUpdate(lookup as CFDictionary, update)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw NativeGoogleIntegrationError.keychainFailure(updated)
        }
        var item = lookup
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw NativeGoogleIntegrationError.keychainFailure(added)
        }
    }

    private func loadToken(accountID: String, identity: String) throws -> GoogleTokenRecord {
        var query = keychainLookup(accountID: accountID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = try? JSONDecoder().decode(GoogleTokenRecord.self, from: data) else {
            if status == errSecItemNotFound { throw NativeGoogleIntegrationError.tokenUnavailable(identity) }
            throw NativeGoogleIntegrationError.keychainFailure(status)
        }
        return token
    }

    private func removeToken(accountID: String) throws {
        let status = SecItemDelete(keychainLookup(accountID: accountID) as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw NativeGoogleIntegrationError.keychainFailure(status)
        }
    }

    private func keychainLookup(accountID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: accountID,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    private var clientConfigurationURL: URL { rootDirectory.appending(path: "oauth-client.json") }
    private var accountIndexURL: URL { rootDirectory.appending(path: "accounts.json") }
}

public enum GoogleAPIResponseParser {
    public struct CalendarPage: Equatable, Sendable {
        public let calendars: [PersonalCalendarSourceSnapshot]
        public let nextPageToken: String?
    }

    public static func calendars(data: Data, account: NativeGoogleAccountSnapshot) throws -> [PersonalCalendarSourceSnapshot] {
        try calendarPage(data: data, account: account).calendars
    }

    public static func calendarPage(data: Data, account: NativeGoogleAccountSnapshot) throws -> CalendarPage {
        struct Response: Decodable {
            struct Item: Decodable {
                let id: String
                let summary: String
                let accessRole: String
                let primary: Bool?
            }
            let items: [Item]?
            let nextPageToken: String?
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            let calendars = response.items?.map {
                PersonalCalendarSourceSnapshot(
                    accountIdentity: account.identity,
                    externalIdentifier: $0.id,
                    name: $0.summary,
                    role: $0.accessRole,
                    isPrimary: $0.primary ?? false
                )
            } ?? []
            return CalendarPage(calendars: calendars, nextPageToken: response.nextPageToken)
        } catch {
            throw NativeGoogleIntegrationError.invalidResponse("Google Calendar")
        }
    }

    public static func threadReferences(data: Data) throws -> [String] {
        struct Response: Decodable {
            struct Thread: Decodable { let id: String }
            let threads: [Thread]?
        }
        do { return try JSONDecoder().decode(Response.self, from: data).threads?.map(\.id) ?? [] }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Gmail") }
    }

    public static func thread(data: Data, account: NativeGoogleAccountSnapshot) throws -> PersonalMailThreadSnapshot {
        struct Thread: Decodable {
            struct Message: Decodable {
                struct Payload: Decodable {
                    struct Header: Decodable { let name: String; let value: String }
                    let headers: [Header]?
                }
                let labelIds: [String]?
                let payload: Payload?
            }
            let id: String
            let snippet: String?
            let messages: [Message]?
        }
        do {
            let decoded = try JSONDecoder().decode(Thread.self, from: data)
            let messages = decoded.messages ?? []
            let headers = messages.last?.payload?.headers ?? []
            func header(_ name: String) -> String? {
                headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
            }
            let labels = Set(messages.flatMap { $0.labelIds ?? [] }).sorted().joined(separator: ", ")
            return PersonalMailThreadSnapshot(
                accountIdentity: account.identity,
                externalIdentifier: decoded.id,
                flags: labels,
                sender: header("From") ?? "Unknown sender",
                subject: header("Subject") ?? "(No subject)",
                snippet: decoded.snippet ?? "",
                dateDescription: header("Date") ?? "",
                messageCount: max(messages.count, 1)
            )
        } catch let error as NativeGoogleIntegrationError {
            throw error
        } catch {
            throw NativeGoogleIntegrationError.invalidResponse("Gmail")
        }
    }
}

#if os(macOS)
private final class GoogleLoopbackReceiver: @unchecked Sendable {
    let redirectURI: URL
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URLComponents), Error>?
    private var pendingComponents: URLComponents?

    private init(listener: NWListener, redirectURI: URL) {
        self.listener = listener
        self.redirectURI = redirectURI
    }

    static func start() async throws -> GoogleLoopbackReceiver {
        let listener = try NWListener(using: .tcp, on: .any)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port,
                          let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else {
                        listener.cancel()
                        continuation.resume(throwing: NativeGoogleIntegrationError.authorizationUnavailable)
                        return
                    }
                    let receiver = GoogleLoopbackReceiver(listener: listener, redirectURI: redirect)
                    listener.newConnectionHandler = receiver.accept
                    continuation.resume(returning: receiver)
                case .failed:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: NativeGoogleIntegrationError.authorizationUnavailable)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "com.cyberlane.kaname.google-oauth"))
        }
    }

    func waitForCode(expectedState: String) async throws -> String {
        let components = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pendingComponents {
                    lock.unlock()
                    continuation.resume(returning: pendingComponents)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel()
        }
        listener.cancel()
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        if query["error"] != nil { throw NativeGoogleIntegrationError.authorizationCancelled }
        guard query["state"] == expectedState, let code = query["code"], !code.isEmpty else {
            throw NativeGoogleIntegrationError.invalidAuthorizationCallback
        }
        return code
    }

    func cancel() {
        listener.cancel()
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: NativeGoogleIntegrationError.authorizationCancelled)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.cyberlane.kaname.google-oauth.connection"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self,
                  let data,
                  let request = String(data: data, encoding: .utf8),
                  let firstLine = request.split(separator: "\r\n").first,
                  firstLine.hasPrefix("GET "),
                  let path = firstLine.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://127.0.0.1\(path)") else {
                connection.cancel()
                return
            }
            let body = "<html><body style='font-family:-apple-system;padding:40px'><h2>Account connected</h2><p>You can return to Kaname.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.deliver(components)
        }
    }

    private func deliver(_ components: URLComponents) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: components)
        } else {
            pendingComponents = components
            lock.unlock()
        }
    }
}
#endif

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }
}
