import Foundation

/// The last good readings on disk, so the panel has numbers the moment UsageHUD launches, and
/// the backoff survives a relaunch. Numbers, dates and plan names only: never a token
/// (`<home>/usage-cache.json`, created mode 0600).
public struct UsageCache: Codable, Equatable, Sendable {
    public static let fileName = "usage-cache.json"
    public static let version = 1

    public var version: Int
    public var records: [String: ProviderRecord]
    /// The Keychain item as it was when `security` was refused it: not read again until it
    /// changes or the owner refreshes, across relaunches too.
    public var claudeBlocked: CredentialStamp?

    public init(records: [Provider: ProviderRecord] = [:], claudeBlocked: CredentialStamp? = nil) {
        version = Self.version
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
        self.claudeBlocked = claudeBlocked
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

    /// Writes a temporary file created 0600, then renames it over `url`: the cache is never
    /// readable by others, not even for a moment.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoded()
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        unlink(temporary.path)   // a leftover from a crash
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporary.path]) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
