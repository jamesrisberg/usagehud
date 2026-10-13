import Foundation

/// The two subscriptions UsageHUD reads.
public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// One usage window of a subscription: how much of it is spent and when it starts over.
public struct UsageWindow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The five-hour window.
        case session
        /// The seven-day window every model shares.
        case weekly
        /// A seven-day cap on one model (Claude's Opus, Sonnet or top-model row).
        case model
        /// A 28-31 day window (Codex team plans).
        case monthly
        /// Any other window the provider reports (Claude's OAuth apps, Cowork).
        case other
    }

    public var id: String
    public var label: String
    public var kind: Kind
    /// 0-100, nil when the provider reported the window without a number.
    public var percentUsed: Double?
    public var resetsAt: Date?
    public var windowSeconds: Int?

    public init(id: String, label: String, kind: Kind, percentUsed: Double?, resetsAt: Date?, windowSeconds: Int?) {
        self.id = id
        self.label = label
        self.kind = kind
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }
}

/// Codex's credit balance.
public struct Credits: Codable, Equatable, Sendable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: Double?

    public init(hasCredits: Bool, unlimited: Bool, balance: Double?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

/// A good reading of one provider: numbers only, never a credential.
public struct UsageReading: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The provider's usage endpoint.
        case live
        /// The newest `rate_limits` record in Codex's session logs.
        case sessionLog
    }

    public var windows: [UsageWindow]
    public var credits: Credits?
    /// The plan as the provider names it (`max`, `pro`, `plus`), when known.
    public var plan: String?
    /// When the numbers were true: the fetch time, or the session log record's timestamp.
    public var observedAt: Date
    public var source: Source

    public init(windows: [UsageWindow], credits: Credits? = nil, plan: String? = nil, observedAt: Date, source: Source = .live) {
        self.windows = windows
        self.credits = credits
        self.plan = plan
        self.observedAt = observedAt
        self.source = source
    }
}

extension UsageWindow {
    /// Whether the window has started over since the reading: its old number no longer holds.
    public func hasReset(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// The percentage that still holds at `now`: nil once the window has reset.
    public func currentPercent(at now: Date) -> Double? { hasReset(at: now) ? nil : percentUsed }
}

extension UsageReading {
    /// The windows worth a meter: every session, weekly and monthly window, the top model's
    /// weekly cap, and the other per-model and extra windows (Opus, OAuth apps, Cowork) only
    /// once they have been used.
    public var meterWindows: [UsageWindow] {
        windows.filter { window in
            switch window.kind {
            case .session, .weekly, .monthly: return true
            case .model: return window.id == "seven_day_model" || (window.percentUsed ?? 0) > 0
            case .other: return (window.percentUsed ?? 0) > 0
            }
        }
    }
}

/// Why the last attempt at a provider did not produce a reading.
public enum FetchProblem: Codable, Equatable, Sendable {
    /// No credentials: never signed in, or signed out.
    case signedOut
    /// The stored access token has expired. UsageHUD never refreshes it: the CLI that owns it does.
    case expired
    /// The endpoint refused the token (401).
    case unauthorized
    /// The Keychain would not hand `/usr/bin/security` Claude Code's item without asking (or
    /// the tool did not answer in time). Not tried again until the item changes or the owner
    /// refreshes.
    case keychainNeedsApproval
    /// The endpoint answered 429.
    case rateLimited
    /// Any other HTTP status.
    case server(Int)
    /// The request did not complete (offline, DNS, timeout).
    case network(String)
    /// A 2xx answer UsageHUD could not read.
    case badPayload
    /// The credentials store could not be read for another reason.
    case credentials(String)

    /// Whether this problem came from a request that reached (or tried to reach) the
    /// provider. A panel opening waits out the backoff of these; a local problem (signed out,
    /// expired, the Keychain) is checked again at once, since checking it sends nothing.
    public var isRemote: Bool {
        switch self {
        case .unauthorized, .rateLimited, .server, .network, .badPayload: return true
        case .signedOut, .expired, .keychainNeedsApproval, .credentials: return false
        }
    }

    /// Whether the owner has to sign in again (or answer the Keychain) before a reading can come.
    public var needsSignIn: Bool {
        switch self {
        case .signedOut, .expired, .unauthorized, .keychainNeedsApproval: return true
        default: return false
        }
    }

    /// A short machine name for `usage` replies.
    public var code: String {
        switch self {
        case .signedOut: return "signedOut"
        case .expired: return "expired"
        case .unauthorized: return "unauthorized"
        case .keychainNeedsApproval: return "keychainNeedsApproval"
        case .rateLimited: return "rateLimited"
        case .server: return "server"
        case .network: return "network"
        case .badPayload: return "badPayload"
        case .credentials: return "credentials"
        }
    }

    /// One plain line for the panel.
    public func hint(for provider: Provider) -> String {
        switch (self, provider) {
        case (.signedOut, .claude): return "Sign in with Claude Code to see usage"
        case (.signedOut, .codex), (.expired, .codex), (.unauthorized, .codex): return "Run codex to sign in"
        case (.expired, .claude), (.unauthorized, .claude): return "Open Claude Code to refresh your sign-in"
        case (.keychainNeedsApproval, _): return "The Keychain held back Claude Code's sign-in. Refresh to try again"
        case (.rateLimited, _): return "\(provider.displayName) is rate-limiting usage reads"
        case (.server(let status), _): return "\(provider.displayName) answered \(status)"
        case (.network, _): return "Can't reach \(provider.displayName)"
        case (.badPayload, _): return "\(provider.displayName) sent usage UsageHUD can't read"
        case (.credentials(let why), _): return why
        }
    }
}

/// Everything UsageHUD knows about one provider: the last good reading and how the last attempt went.
public struct ProviderRecord: Codable, Equatable, Sendable {
    /// The last good reading, kept when later attempts fail.
    public var reading: UsageReading?
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    /// The last attempt's problem; nil when it succeeded (or nothing was tried yet).
    public var problem: FetchProblem?
    /// How many failures in a row backed off; 0 after a success.
    public var backoffLevel: Int
    /// No scheduled attempt before this.
    public var retryAt: Date?

    public init(reading: UsageReading? = nil, lastAttemptAt: Date? = nil, lastSuccessAt: Date? = nil,
                problem: FetchProblem? = nil, backoffLevel: Int = 0, retryAt: Date? = nil) {
        self.reading = reading
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.problem = problem
        self.backoffLevel = backoffLevel
        self.retryAt = retryAt
    }
}
