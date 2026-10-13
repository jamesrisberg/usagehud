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
/// a request's credentials nor an answer is ever written to disk.
public final class URLSessionTransport: UsageTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
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
}

/// What a credentials lookup found.
public enum CredentialLookup<Token: Sendable>: Sendable {
    case found(Token)
    /// No credentials stored: not signed in.
    case missing
    /// The owner denied access (Keychain).
    case denied
    /// Reading would prompt, and this read was not allowed to (Keychain).
    case needsApproval
    case failed(String)
}

/// Reads Claude Code's token. `allowPrompt` false must never show the Keychain's prompt. A read
/// that prompts waits for the owner, so it is async and must not block the caller's thread.
public protocol ClaudeTokenSource: Sendable {
    func read(allowPrompt: Bool) async -> CredentialLookup<ClaudeToken>
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

/// Why a read was started. Only `user` bypasses the backoff and may show the Keychain prompt
/// after the first launch.
public enum RefreshTrigger: String, Sendable {
    /// The poll timer.
    case scheduled
    /// Launch or the panel opening: skipped when the last attempt is under a minute old.
    case opportunistic
    /// The owner asked (refresh button, `usagehud refresh`).
    case user

    var minimumSpacing: TimeInterval {
        switch self {
        case .scheduled: return 30
        case .opportunistic: return 60
        case .user: return 0
        }
    }
}

/// Reads both providers' usage, read-only: it sends the two usage GETs and nothing else. It
/// never refreshes, rotates or writes a token (both CLIs rotate their refresh tokens, so a
/// refresh here would sign the owner out of Claude Code or Codex); an expired token is
/// reported as such and the last good reading is shown as stale.
public actor UsageService {
    public typealias Clock = @Sendable () -> Date

    private let transport: UsageTransport
    private let claudeSource: ClaudeTokenSource
    private let codexSource: CodexTokenSource
    private let sessionLog: CodexSessionLog?
    private let clock: Clock
    private let cacheURL: URL?

    private var records: [Provider: ProviderRecord]
    public private(set) var keychainAccess: KeychainAccess
    /// Claude's token stays in memory (never on disk) until it expires or is refused, so the
    /// Keychain is read once per sign-in, not once per poll.
    private var claudeToken: ClaudeToken?
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
        keychainAccess = cache.keychainAccess
    }

    public func snapshot() -> [Provider: ProviderRecord] { records }

    public func record(_ provider: Provider) -> ProviderRecord { records[provider] ?? ProviderRecord() }

    /// Reads one provider unless the trigger says to wait. Returns the record afterwards.
    @discardableResult
    public func refresh(_ provider: Provider, trigger: RefreshTrigger) async -> ProviderRecord {
        let now = clock()
        let current = record(provider)
        guard !inFlight.contains(provider) else { return current }
        if trigger != .user, current.shouldWait(at: now, minimumSpacing: trigger.minimumSpacing) { return current }
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

    private func refreshClaude(_ current: ProviderRecord, trigger: RefreshTrigger) async -> ProviderRecord {
        let now = clock()
        var fromMemory = true
        if claudeToken == nil || claudeToken!.isExpired(at: now) {
            claudeToken = nil
            fromMemory = false
            if let problem = await readClaudeToken(trigger: trigger) { return current.failed(problem, at: clock()) }
        }
        guard let token = claudeToken else { return current.failed(.signedOut, at: now) }
        if token.isExpired(at: now) {
            claudeToken = nil
            return current.failed(.expired, at: now)
        }
        let response = await transport.send(ClaudeUsage.request(token: token))
        if Self.refused(response) {
            claudeToken = nil
            // A token held in memory may have been replaced since: Claude Code refreshed it.
            // Read the store once more and retry once with a different token.
            if fromMemory, await readClaudeToken(trigger: trigger) == nil, let fresh = claudeToken, fresh != token {
                let retry = await transport.send(ClaudeUsage.request(token: fresh))
                if Self.refused(retry) { claudeToken = nil }
                return outcome(of: retry, current: current) { ClaudeUsage.reading(from: $0, plan: fresh.subscriptionType, at: $1) }
            }
            claudeToken = nil
        }
        return outcome(of: response, current: current) { ClaudeUsage.reading(from: $0, plan: token.subscriptionType, at: $1) }
    }

    /// Fills `claudeToken`, or returns why it could not. The first read ever, and a read the
    /// owner asked for, may show the Keychain prompt; a scheduled read after access was granted
    /// never does, and after a denial only an explicit refresh asks again.
    private func readClaudeToken(trigger: RefreshTrigger) async -> FetchProblem? {
        let allowPrompt: Bool
        switch keychainAccess {
        case .unknown: allowPrompt = true
        case .granted: allowPrompt = trigger == .user
        case .denied:
            guard trigger == .user else { return .keychainDenied }
            allowPrompt = true
        }
        switch await claudeSource.read(allowPrompt: allowPrompt) {
        case .found(let token):
            keychainAccess = .granted
            claudeToken = token
            return token.isExpired(at: clock()) ? .expired : nil
        case .missing: return .signedOut
        case .denied:
            keychainAccess = .denied
            return .keychainDenied
        case .needsApproval: return .keychainNeedsApproval
        case .failed(let why): return .credentials(why)
        }
    }

    // MARK: Codex

    private func refreshCodex(_ current: ProviderRecord) async -> ProviderRecord {
        let now = clock()
        let next: ProviderRecord
        switch codexSource.read() {
        case .found(let token) where token.isExpired(at: now):
            next = current.failed(.expired, at: now)
        case .found(let token):
            let response = await transport.send(CodexUsage.request(token: token))
            next = outcome(of: response, current: current) { CodexUsage.reading(from: $0, at: $1) }
        case .missing, .denied, .needsApproval:
            next = current.failed(.signedOut, at: now)
        case .failed(let why):
            next = current.failed(.credentials(why), at: now)
        }
        guard next.problem != nil else { return next }
        return withSessionLogFallback(next)
    }

    /// After a failed read, the newest `rate_limits` record in Codex's session logs replaces
    /// the reading when it is newer than the one held.
    private func withSessionLogFallback(_ record: ProviderRecord) -> ProviderRecord {
        guard let logged = sessionLog?.latestReading() else { return record }
        var next = record
        if logged.observedAt > (record.reading?.observedAt ?? .distantPast) { next.reading = logged }
        return next
    }

    // MARK: Shared

    private static func refused(_ response: TransportResponse) -> Bool { response.status == 401 || response.status == 403 }

    private func outcome(of response: TransportResponse, current: ProviderRecord,
                         decode: (Data, Date) -> UsageReading?) -> ProviderRecord {
        let now = clock()
        guard let status = response.status else {
            return current.failed(.network(response.failure ?? "no answer"), at: now)
        }
        switch status {
        case 200..<300:
            guard let reading = decode(response.body, now) else { return current.failed(.badPayload, at: now) }
            return current.succeeded(with: reading, at: now)
        case 401, 403:
            return current.failed(.unauthorized, at: now)
        case 429:
            return current.failed(.rateLimited, at: now, retryAfter: Backoff.retryAfter(response.header("Retry-After"), now: now))
        default:
            return current.failed(.server(status), at: now, retryAfter: Backoff.retryAfter(response.header("Retry-After"), now: now))
        }
    }

    private func persist() {
        guard let cacheURL else { return }
        do {
            try UsageCache(records: records, keychainAccess: keychainAccess).save(to: cacheURL)
        } catch {
            NSLog("UsageHUD: could not save the usage cache: %@", String(describing: error))
        }
    }
}
