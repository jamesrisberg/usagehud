import Foundation

/// UsageHUD's settings: the values behind Resources/settings.json, persisted as JSON in
/// `<home>/preferences.json`. Values arrive over the socket as strings (`settings set k=v`),
/// so `applying(_:)` parses and validates them all before changing anything.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Minutes between reads (1-60).
    public var pollMinutes: Int
    public var claudeEnabled: Bool
    public var codexEnabled: Bool

    public init(pollMinutes: Int = 5, claudeEnabled: Bool = true, codexEnabled: Bool = true) {
        self.pollMinutes = pollMinutes
        self.claudeEnabled = claudeEnabled
        self.codexEnabled = codexEnabled
    }

    public static let pollRange = 1...60
    /// The keys `settings get` reports and `settings set` accepts (Resources/settings.json).
    public static let keys: Set<String> = ["pollMinutes", "claudeEnabled", "codexEnabled"]

    public func isEnabled(_ provider: Provider) -> Bool {
        switch provider {
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        }
    }

    public var enabledProviders: [Provider] { Provider.allCases.filter(isEnabled) }

    /// Saved values are merged over the defaults key by key: a key missing from
    /// `preferences.json` (written before the setting existed) or one that does not decode
    /// keeps its default, and every other saved value is kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        pollMinutes = Self.value(c, .pollMinutes, default: d.pollMinutes)
        claudeEnabled = Self.value(c, .claudeEnabled, default: d.claudeEnabled)
        codexEnabled = Self.value(c, .codexEnabled, default: d.codexEnabled)
        if !Self.pollRange.contains(pollMinutes) { pollMinutes = d.pollMinutes }
    }

    private static func value<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K, default fallback: T) -> T {
        ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    public enum SettingsError: Error, Equatable, CustomStringConvertible {
        case unknownKey(String)
        case invalid(key: String, value: String)

        public var description: String {
            switch self {
            case .unknownKey(let key): return "unknown setting \(key)"
            case .invalid(let key, let value): return "invalid value \(value) for \(key)"
            }
        }
    }

    /// The settings with `values` applied; throws on the first unknown key or bad value.
    public func applying(_ values: [String: String]) throws -> AppSettings {
        var next = self
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "pollMinutes":
                guard let minutes = Int(value.trimmingCharacters(in: .whitespaces)), Self.pollRange.contains(minutes) else {
                    throw SettingsError.invalid(key: key, value: value)
                }
                next.pollMinutes = minutes
            case "claudeEnabled", "codexEnabled":
                guard let flag = Self.bool(value) else { throw SettingsError.invalid(key: key, value: value) }
                if key == "claudeEnabled" { next.claudeEnabled = flag } else { next.codexEnabled = flag }
            default:
                throw SettingsError.unknownKey(key)
            }
        }
        return next
    }

    /// `settings get`'s payload.
    public var json: [String: Any] { ["pollMinutes": pollMinutes, "claudeEnabled": claudeEnabled, "codexEnabled": codexEnabled] }

    static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    // MARK: Persistence

    /// Reads the settings at `url`, saved values over the defaults (see `init(from:)`); defaults
    /// when the file is missing or not a JSON object.
    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
