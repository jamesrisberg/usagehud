import Foundation

/// The answer to one HTTP request: a status, or the reason there was none.
public struct TransportResponse: Sendable {
    public var status: Int?
    public var headers: [String: String]
    public var body: Data
    public var failure: String?

    public init(status: Int?, headers: [String: String] = [:], body: Data = Data(), failure: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.failure = failure
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Sends the usage requests. Tests substitute a recording fake.
public protocol UsageTransport: Sendable {
    func send(_ request: URLRequest) async -> TransportResponse
}

/// The real transport: an ephemeral session with no cookie store and no URL cache, so neither
/// a request's credentials nor an answer is ever written to disk. Redirects are refused: the
/// 3xx itself is the answer (read as a server error), so the bearer, the account id and the
/// user agent never follow a redirect to another address.
public final class URLSessionTransport: UsageTransport, @unchecked Sendable {
    private let session: URLSession

    /// `protocolClasses` lets tests answer requests in-process.
    public init(protocolClasses: [AnyClass] = []) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? []) }
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async -> TransportResponse {
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return TransportResponse(status: http?.statusCode, headers: headers, body: data)
        } catch {
            return TransportResponse(status: nil, failure: (error as NSError).localizedDescription)
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// What a credentials lookup found.
public enum CredentialLookup<Token: Sendable>: Sendable {
    case found(Token)
    /// No credentials stored: not signed in.
    case missing
    /// The Keychain would not hand the item over without asking.
    case needsApproval
    case failed(String)
}

/// Which store holds Claude Code's sign-in, and when it last changed. Reading it never touches
/// the secret, so it is free and never asks anything.
public struct CredentialStamp: Codable, Equatable, Sendable {
    public enum Location: String, Codable, Sendable {
        /// `<config>/.credentials.json`
        case file
        /// The login Keychain item.
        case keychain
    }

    public var location: Location
    /// The file's or the item's modification date; nil when the store does not say.
    public var modified: Date?

    public init(location: Location, modified: Date?) {
        self.location = location
        self.modified = modified
    }
}

public enum StampLookup: Sendable {
    case present(CredentialStamp)
    case missing
    case failed(String)
}

/// Claude Code's credentials store. `stamp()` reads only metadata (the file's modification
/// date, the Keychain item's attributes); `read(_:patient:)` reads the secret. `patient` is the
/// owner's own refresh, which may wait longer for the Keychain.
public protocol ClaudeTokenSource: Sendable {
    func stamp() async -> StampLookup
    func read(_ location: CredentialStamp.Location, patient: Bool) async -> CredentialLookup<ClaudeToken>
}

/// Reads Codex's token.
public protocol CodexTokenSource: Sendable {
    func read() -> CredentialLookup<CodexToken>
}

/// `<codex home>/auth.json`, read fresh on every attempt so a sign-in Codex refreshed is picked up.
public struct CodexAuthFile: CodexTokenSource {
    public let url: URL

    public init(codexHome: URL) { url = codexHome.appendingPathComponent("auth.json") }

    public func read() -> CredentialLookup<CodexToken> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .failed("Can't read Codex's auth.json") }
        return CodexToken.parse(data).map { .found($0) } ?? .missing
    }
}

/// Why a read was started.
public enum RefreshTrigger: String, Sendable {
    /// The poll timer, and launch.
    case scheduled
    /// The panel opening (or a provider turned on).
    case panelOpen
    /// The owner asked (refresh button, menu, `usagehud refresh`): past any backoff, and past
    /// a Keychain refusal.
    case user
}

/// Reads both providers' usage, read-only: it sends the two usage GETs and nothing else. It
/// never refreshes, rotates or writes a token (both CLIs rotate their refresh tokens, so a
/// refresh here would sign the owner out of Claude Code or Codex); an expired token is
/// reported as such and the last good reading is shown as stale.
///
/// Claude's secret is read only when it is needed: when no token is held, when the store's
/// stamp (its modification date) changed since the token was read, or once per held token
/// after it expires or is refused (the date has one-second resolution, so two rewrites inside a
/// second can leave it unchanged while the secret moved on). Past that one read, an expired
/// token in an unchanged store costs a metadata read and nothing else. After the Keychain refused
/// `security`, the item is not read again until it changes or the owner refreshes.
public actor UsageService {
    public typealias Clock = @Sendable () -> Date

    private let transport: UsageTransport
    private let claudeSource: ClaudeTokenSource
    private let codexSource: CodexTokenSource
    private let sessionLog: CodexSessionLog?
    private let clock: Clock
    private let cacheURL: URL?

    private var records: [Provider: ProviderRecord]
    /// The Keychain item as it was when `security` was refused it.
    public private(set) var claudeBlocked: CredentialStamp?
    /// Claude's token, held in memory only (never on disk), with the stamp of the store it came
    /// from and whether its one fresh read on an unchanged stamp has been spent.
    private var claude: (token: ClaudeToken, stamp: CredentialStamp, freshReadSpent: Bool)?
    private var inFlight: Set<Provider> = []

    public init(transport: UsageTransport, claudeSource: ClaudeTokenSource, codexSource: CodexTokenSource,
                sessionLog: CodexSessionLog?, cacheURL: URL?, clock: @escaping Clock = { Date() }) {
        self.transport = transport
        self.claudeSource = claudeSource
        self.codexSource = codexSource
        self.sessionLog = sessionLog
        self.cacheURL = cacheURL
        self.clock = clock
        let cache = cacheURL.map(UsageCache.load(from:)) ?? UsageCache()
        records = cache.providerRecords
        claudeBlocked = cache.claudeBlocked
    }

    public func snapshot() -> [Provider: ProviderRecord] { records }

    public func record(_ provider: Provider) -> ProviderRecord { records[provider] ?? ProviderRecord() }

    /// Reads one provider unless the trigger says to wait. Returns the record afterwards.
    @discardableResult
    public func refresh(_ provider: Provider, trigger: RefreshTrigger) async -> ProviderRecord {
        let current = record(provider)
        guard !inFlight.contains(provider), !current.shouldWait(at: clock(), trigger: trigger) else { return current }
        inFlight.insert(provider)
        let next: ProviderRecord
        switch provider {
        case .claude: next = await refreshClaude(current, trigger: trigger)
        case .codex: next = await refreshCodex(current)
        }
        inFlight.remove(provider)
        records[provider] = next
        persist()
        return next
    }

    // MARK: Claude

    /// Every Claude failure backs off.
    private func refreshClaude(_ current: ProviderRecord, trigger: RefreshTrigger) async -> ProviderRecord {
        let stamp: CredentialStamp
        switch await claudeSource.stamp() {
        case .present(let found): stamp = found
        case .missing:
            claude = nil
            return current.failed(.signedOut, at: clock())
        case .failed(let why):
            return current.failed(.credentials(why), at: clock())
        }
        if let problem = await holdClaudeToken(stamp: stamp, trigger: trigger) { return current.failed(problem, at: clock()) }
        guard let held = claude else { return current.failed(.signedOut, at: clock()) }
        if held.token.isExpired(at: clock()) { return current.failed(.expired, at: clock()) }

        let response = await transport.send(ClaudeUsage.request(token: held.token))
        if response.status == 401 {
            // Refused. Claude Code may have replaced the token since it was read: read the store
            // again (if it changed, or as this token's one fresh read) and retry once with a
            // different token.
            if case .present(let now) = await claudeSource.stamp(),
               await holdClaudeToken(stamp: now, trigger: trigger, refused: true) == nil,
               let fresh = claude, fresh.token != held.token, !fresh.token.isExpired(at: clock()) {
                let retry = await transport.send(ClaudeUsage.request(token: fresh.token))
                return outcome(of: retry, current: current, backOff: true) {
                    ClaudeUsage.reading(from: $0, plan: fresh.token.subscriptionType, at: $1)
                }
            }
        }
        return outcome(of: response, current: current, backOff: true) {
            ClaudeUsage.reading(from: $0, plan: held.token.subscriptionType, at: $1)
        }
    }

    /// Makes sure `claude` holds the token of the store as `stamp` describes it, reading the
    /// secret only when needed. `refused`: the held token just got a 401. Returns why it could not.
    private func holdClaudeToken(stamp: CredentialStamp, trigger: RefreshTrigger, refused: Bool = false) async -> FetchProblem? {
        var freshRead = false
        if let held = claude, held.stamp == stamp {
            // Unchanged store: keep a token that still works. One that expired or was refused
            // earns one fresh read; a store that keeps no modification date is read whenever its
            // token has gone, since nothing else would tell that it changed.
            guard refused || held.token.isExpired(at: clock()) else { return nil }
            if stamp.modified != nil {
                guard !held.freshReadSpent else { return nil }
                freshRead = true
            }
        }
        if stamp.location == .keychain, let blocked = claudeBlocked, blocked == stamp, trigger != .user {
            return .keychainNeedsApproval
        }
        switch await claudeSource.read(stamp.location, patient: trigger == .user) {
        case .found(let token):
            // A fresh read that found the same token has spent it; a new token earns its own.
            claude = (token, stamp, freshRead && claude?.token == token)
            if stamp.location == .keychain { claudeBlocked = nil }
            return nil
        case .missing:
            claude = nil
            return .signedOut
        case .needsApproval:
            claude = nil
            if stamp.location == .keychain { claudeBlocked = stamp }
            return .keychainNeedsApproval
        case .failed(let why):
            return .credentials(why)
        }
    }

    // MARK: Codex

    /// Codex's network failures back off; its local ones (signed out, expired) send nothing,
    /// so they are checked again at the next poll, and the session log fills in meanwhile.
    private func refreshCodex(_ current: ProviderRecord) async -> ProviderRecord {
        let now = clock()
        let next: ProviderRecord
        switch codexSource.read() {
        case .found(let token) where token.isExpired(at: now):
            next = current.failed(.expired, at: now, backOff: false)
        case .found(let token):
            let response = await transport.send(CodexUsage.request(token: token))
            next = outcome(of: response, current: current, backOff: true) { CodexUsage.reading(from: $0, at: $1) }
        case .missing, .needsApproval:
            next = current.failed(.signedOut, at: now, backOff: false)
        case .failed(let why):
            next = current.failed(.credentials(why), at: now, backOff: false)
        }
        guard next.problem != nil else { return next }
        return await withSessionLogFallback(next)
    }

    /// After a failed read, the newest `rate_limits` record in Codex's session logs replaces
    /// the reading when it is newer than the one held. The logs are read off the actor.
    private func withSessionLogFallback(_ record: ProviderRecord) async -> ProviderRecord {
        guard let sessionLog else { return record }
        let logged = await Task.detached(priority: .utility) { sessionLog.latestReading() }.value
        guard let logged else { return record }
        var next = record
        if logged.observedAt > (record.reading?.observedAt ?? .distantPast) { next.reading = logged }
        return next
    }

    // MARK: Shared

    /// 401 is a refused sign-in; 403 and every other status are the provider's error (a 403
    /// from chatgpt.com is usually its edge, not the token).
    private func outcome(of response: TransportResponse, current: ProviderRecord, backOff: Bool,
                         decode: (Data, Date) -> UsageReading?) -> ProviderRecord {
        let now = clock()
        guard let status = response.status else {
            return current.failed(.network(response.failure ?? "no answer"), at: now, backOff: backOff)
        }
        let retryAfter = Backoff.retryAfter(response.header("Retry-After"), now: now)
        switch status {
        case 200..<300:
            guard let reading = decode(response.body, now) else { return current.failed(.badPayload, at: now, backOff: backOff) }
            return current.succeeded(with: reading, at: now)
        case 401:
            return current.failed(.unauthorized, at: now, backOff: backOff)
        case 429:
            return current.failed(.rateLimited, at: now, retryAfter: retryAfter, backOff: backOff)
        default:
            return current.failed(.server(status), at: now, retryAfter: retryAfter, backOff: backOff)
        }
    }

    private func persist() {
        guard let cacheURL else { return }
        do {
            try UsageCache(records: records, claudeBlocked: claudeBlocked).save(to: cacheURL)
        } catch {
            NSLog("UsageHUD: could not save the usage cache: %@", String(describing: error))
        }
    }
}
