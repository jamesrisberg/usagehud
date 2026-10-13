import CryptoKit
import Foundation

/// Claude's subscription usage: `GET https://api.anthropic.com/api/oauth/usage` with Claude
/// Code's OAuth access token. The request, the credential format and the payload handling
/// mirror CLIProxyAPI's management web UI.
public enum ClaudeUsage {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The usage request. A GET with the bearer and the OAuth beta header, nothing else: no
    /// body, and never a refresh token.
    public static func request(token: ClaudeToken) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    /// The named windows of the payload, in display order. `iguana_necktie` is the top model's
    /// weekly cap under its internal name; a `limits[]` `weekly_scoped` entry supersedes it and
    /// carries the provider's own display name.
    static let windowKeys: [(key: String, id: String, label: String, kind: UsageWindow.Kind, seconds: Int)] = [
        ("five_hour", "five_hour", "Session", .session, 5 * 3600),
        ("seven_day", "seven_day", "Weekly", .weekly, 7 * 86400),
        ("seven_day_opus", "seven_day_opus", "Opus weekly", .model, 7 * 86400),
        ("seven_day_sonnet", "seven_day_sonnet", "Sonnet weekly", .model, 7 * 86400),
        ("iguana_necktie", "seven_day_model", "Fable weekly", .model, 7 * 86400),
        ("seven_day_oauth_apps", "seven_day_oauth_apps", "OAuth apps weekly", .other, 7 * 86400),
        ("seven_day_cowork", "seven_day_cowork", "Cowork weekly", .other, 7 * 86400),
    ]

    /// The payload's windows, or nil when it has none UsageHUD can read.
    public static func windows(from payload: Any?) -> [UsageWindow]? {
        guard let payload = payload as? [String: Any] else { return nil }
        let limits = payload["limits"] as? [[String: Any]] ?? []
        let scoped = limits.filter { $0["kind"] as? String == "weekly_scoped" && PayloadValues.number($0["percent"]) != nil }
        let modelLimit = scoped.first { PayloadValues.bool($0["is_active"]) == true } ?? scoped.first

        var windows: [UsageWindow] = []
        for spec in windowKeys {
            if spec.key == "iguana_necktie", modelLimit != nil { continue }
            guard let window = payload[spec.key] as? [String: Any], window.keys.contains("utilization") else { continue }
            windows.append(UsageWindow(id: spec.id, label: spec.label, kind: spec.kind,
                                       percentUsed: PayloadValues.percent(window["utilization"]),
                                       resetsAt: PayloadValues.date(window["resets_at"]),
                                       windowSeconds: spec.seconds))
        }
        if let modelLimit {
            let name = ((modelLimit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let label = name.map { "\($0) weekly" } ?? "Top model weekly"
            let window = UsageWindow(id: "seven_day_model", label: label, kind: .model,
                                     percentUsed: PayloadValues.percent(modelLimit["percent"]),
                                     resetsAt: PayloadValues.date(modelLimit["resets_at"]),
                                     windowSeconds: 7 * 86400)
            // After the other model rows, before the extras.
            let index = windows.firstIndex { $0.kind == .other } ?? windows.endIndex
            windows.insert(window, at: index)
        }
        return windows.isEmpty ? nil : windows
    }

    /// Decodes a response body into a reading.
    public static func reading(from body: Data, plan: String?, at now: Date) -> UsageReading? {
        guard let json = try? JSONSerialization.jsonObject(with: body),
              let windows = windows(from: json) else { return nil }
        return UsageReading(windows: windows, plan: plan, observedAt: now, source: .live)
    }
}

/// Claude Code's OAuth access token, as read from its credentials store. Only what a usage
/// read needs is kept: the access token, its expiry and the plan. The refresh token passes
/// through the JSON parser and is never kept or sent; the access token is sent only to
/// api.anthropic.com, and no description of this value contains it.
public struct ClaudeToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let expiresAt: Date?
    /// `max`, `pro`, `team`, `enterprise`, or nil.
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// Expired, or expiring within `leeway` seconds. A token without an expiry counts as valid.
    public func isExpired(at now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    /// The credentials JSON Claude Code stores (`{"claudeAiOauth": {"accessToken", "expiresAt",
    /// "subscriptionType", ...}}`, `expiresAt` in epoch milliseconds). Nil without an access token.
    public static func parse(_ data: Data) -> ClaudeToken? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        return ClaudeToken(accessToken: access, expiresAt: PayloadValues.date(oauth["expiresAt"]),
                           subscriptionType: oauth["subscriptionType"] as? String)
    }

    public var description: String {
        "ClaudeToken(expiresAt: \(expiresAt.map { "\($0)" } ?? "none"), plan: \(subscriptionType ?? "none"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt as Any, "plan": subscriptionType as Any]) }
}

/// Where Claude Code keeps its credentials on macOS: a plaintext `<config>/.credentials.json`
/// when present, else a generic password in the login Keychain.
public enum ClaudeCredentialsStore {
    /// `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    public static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    public static func plaintextFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment: environment).appendingPathComponent(".credentials.json")
    }

    /// The Keychain item's service: `Claude Code-credentials` for the default config directory;
    /// with `CLAUDE_CONFIG_DIR` (or `CLAUDE_SECURESTORAGE_CONFIG_DIR`) set, a `-` and the first
    /// eight hex digits of the directory's SHA-256 are appended, as Claude Code does.
    public static func keychainService(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let base = "Claude Code-credentials"
        let keyDir: String?
        if let secure = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            keyDir = secure.isEmpty ? nil : secure
        } else if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            keyDir = config
        } else {
            keyDir = nil
        }
        guard let keyDir else { return base }
        let digest = SHA256.hash(data: Data(keyDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return base + "-" + hex.prefix(8)
    }

    /// The Keychain item's account: the login name when it is plain, else `claude-code-user`.
    public static func keychainAccount(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let user = environment["USER"] ?? NSUserName()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, user.unicodeScalars.allSatisfy(allowed.contains) else { return "claude-code-user" }
        return user
    }
}
