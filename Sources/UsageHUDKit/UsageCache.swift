import Foundation

/// Whether the owner has let UsageHUD read Claude Code's Keychain item.
public enum KeychainAccess: String, Codable, Sendable {
    /// Never asked: the first read may show the Keychain's prompt.
    case unknown
    /// A read succeeded; later scheduled reads never prompt.
    case granted
    /// The owner said no; only an explicit refresh asks again.
    case denied
}

/// The last good readings on disk, so the panel has numbers the moment UsageHUD launches, and
/// the backoff survives a relaunch. Numbers, dates and plan names only: never a token
/// (`<home>/usage-cache.json`, mode 0600).
public struct UsageCache: Codable, Equatable, Sendable {
    public static let fileName = "usage-cache.json"
    public static let version = 1

    public var version: Int
    public var records: [String: ProviderRecord]
    public var keychainAccess: KeychainAccess

    public init(records: [Provider: ProviderRecord] = [:], keychainAccess: KeychainAccess = .unknown) {
        version = Self.version
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
        self.keychainAccess = keychainAccess
    }

    public var providerRecords: [Provider: ProviderRecord] {
        Dictionary(uniqueKeysWithValues: records.compactMap { key, value in Provider(rawValue: key).map { ($0, value) } })
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    /// The cache at `url`; empty when the file is missing, unreadable or another version.
    public static func load(from url: URL) -> UsageCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? decoder.decode(UsageCache.self, from: data),
              cache.version == version else { return UsageCache() }
        return cache
    }

    public func save(to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
