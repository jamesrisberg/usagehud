import Foundation

/// Codex's subscription usage: `GET https://chatgpt.com/backend-api/wham/usage` with the
/// ChatGPT access token from `~/.codex/auth.json`. The endpoint rejects unknown user agents,
public enum CodexUsage {
    public static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// The user agent the reference sends; the endpoint answers it.
    public static let userAgent = "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"

    /// The usage request: a GET with the bearer, the user agent and the account id. No body,
    /// and never a refresh token.
    public static func request(token: CodexToken) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let account = token.accountID { request.setValue(account, forHTTPHeaderField: "Chatgpt-Account-Id") }
        return request
    }

    /// One window, classified by its length rather than its position: 5 h is the session,
    /// 7 d the week, 28-31 d a team plan's month. A window marked exhausted with no percentage
    /// reads as 100 %.
    static func window(usedPercent: Any?, seconds rawSeconds: Int?, resetsAt: Date?,
                       fallbackID: String, fallbackSeconds: Int, exhausted: Bool) -> UsageWindow {
        let seconds = rawSeconds ?? fallbackSeconds
        let monthly = seconds >= 28 * 86400 && seconds <= 31 * 86400
        let id: String, label: String, kind: UsageWindow.Kind
        switch seconds {
        case 18000: (id, label, kind) = ("five_hour", "Session", .session)
        case 604800: (id, label, kind) = ("seven_day", "Weekly", .weekly)
        case _ where monthly: (id, label, kind) = ("monthly", "Monthly", .monthly)
        default:
            let hours = seconds / 3600
            (id, label, kind) = (fallbackID, hours >= 48 ? "\(hours / 24)-day" : "\(hours)-hour", .other)
        }
        let percent = PayloadValues.percent(usedPercent) ?? (exhausted ? 100 : nil)
        return UsageWindow(id: id, label: label, kind: kind, percentUsed: percent, resetsAt: resetsAt, windowSeconds: seconds)
    }

    /// The `wham/usage` payload's windows (`rate_limit.primary_window` / `secondary_window`),
    /// or nil when it has none.
    public static func windows(from payload: Any?, now: Date) -> [UsageWindow]? {
        guard let payload = payload as? [String: Any],
              let limit = (payload["rate_limit"] ?? payload["rateLimit"]) as? [String: Any] else { return nil }
        let exhausted = PayloadValues.bool(limit["limit_reached"]) == true || PayloadValues.bool(limit["allowed"]) == false
        func shape(_ raw: Any?, _ fallbackID: String, _ fallbackSeconds: Int) -> UsageWindow? {
            guard let w = raw as? [String: Any] else { return nil }
            var resets = PayloadValues.date(w["reset_at"])
            if resets == nil, let after = PayloadValues.number(w["reset_after_seconds"]), after > 0 {
                resets = now.addingTimeInterval(after)
            }
            return window(usedPercent: w["used_percent"], seconds: PayloadValues.number(w["limit_window_seconds"]).map { Int($0) },
                          resetsAt: resets, fallbackID: fallbackID, fallbackSeconds: fallbackSeconds, exhausted: exhausted)
        }
        return assemble(primary: shape(limit["primary_window"] ?? limit["primaryWindow"], "five_hour", 18000),
                        secondary: shape(limit["secondary_window"] ?? limit["secondaryWindow"], "seven_day", 604800))
    }

    /// Shorter window first; a second window with the first one's id is dropped.
    static func assemble(primary: UsageWindow?, secondary: UsageWindow?) -> [UsageWindow]? {
        var windows = [primary, secondary].compactMap { $0 }
        if windows.count == 2, windows[0].id == windows[1].id { windows.removeLast() }
        windows.sort { ($0.windowSeconds ?? 0) < ($1.windowSeconds ?? 0) }
        return windows.isEmpty ? nil : windows
    }

    /// `credits: {has_credits, unlimited, balance}`; the balance arrives as a decimal string.
    static func credits(from raw: Any?) -> Credits? {
        guard let c = raw as? [String: Any] else { return nil }
        return Credits(hasCredits: PayloadValues.bool(c["has_credits"]) ?? false,
                       unlimited: PayloadValues.bool(c["unlimited"]) ?? false,
                       balance: PayloadValues.number(c["balance"]))
    }

    /// Decodes a response body into a reading: the windows, the credits and the plan.
    public static func reading(from body: Data, at now: Date) -> UsageReading? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let windows = windows(from: json, now: now)
        let credits = credits(from: json["credits"])
        guard windows != nil || credits != nil else { return nil }
        return UsageReading(windows: windows ?? [], credits: credits, plan: json["plan_type"] as? String,
                            observedAt: now, source: .live)
    }
}

/// The ChatGPT access token Codex keeps in `auth.json`. Only the access token, the account id
/// and the token's expiry (its JWT `exp`) are kept. The refresh token passes through the JSON
/// parser and is never kept or sent; the access token is sent only to chatgpt.com, and no
/// description of this value contains it.
public struct CodexToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let accountID: String?
    public let expiresAt: Date?

    public init(accessToken: String, accountID: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    /// `{"tokens": {"access_token", "account_id", ...}}`. Nil without an access token (an API
    /// key login has no subscription usage).
    public static func parse(_ data: Data) -> CodexToken? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        let account = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CodexToken(accessToken: access, accountID: account, expiresAt: jwtExpiry(access))
    }

    /// The `exp` claim of a JWT, without verifying it (only the server's answer is trusted).
    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = PayloadValues.number(claims["exp"]), exp > 0 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    public var description: String {
        "CodexToken(expiresAt: \(expiresAt.map { "\($0)" } ?? "none"), account: \(accountID == nil ? "none" : "set"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt as Any]) }
}

/// Where Codex keeps its files: `CODEX_HOME`, else `~/.codex`.
public enum CodexHome {
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
}
