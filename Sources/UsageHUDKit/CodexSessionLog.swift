import Foundation

/// The offline fallback for Codex: every Codex turn writes a `token_count` event with the
/// account's `rate_limits` into its session log (`<codex home>/sessions/YYYY/MM/DD/*.jsonl`).
/// The newest such record is the last reading Codex itself saw, shown with its age.
///
/// Only the `rate_limits` object and the record's timestamp are read; the rest of the log (the
/// conversation) is never decoded beyond finding that object.
public struct CodexSessionLog: Sendable {
    public let sessionsDirectory: URL
    /// How many of the most recently written log files to look through.
    public var fileLimit = 6
    /// How much of a file is read at a time, from the end backwards.
    public var chunkBytes = 256 * 1024
    /// Each file's last answer, by its identity: an unchanged file is never read twice.
    let memo = Memo()

    public init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    public init(codexHome: URL) {
        self.init(sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true))
    }

    /// The newest reading across the most recently written log files, or nil when none has one.
    public func latestReading() -> UsageReading? {
        var best: UsageReading?
        for file in newestFiles() {
            guard let reading = latestReading(in: file) else { continue }
            if best == nil || reading.observedAt > best!.observedAt { best = reading }
        }
        return best
    }

    /// The `.jsonl` files under the sessions directory written most recently, by modification
    /// date: a long session started days ago, in an older date folder, is still found while
    /// Codex writes to it.
    func newestFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: sessionsDirectory, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.modified > $1.modified }.prefix(fileLimit).map(\.url)
    }

    /// The last record with a `rate_limits` object in one file, read backwards a chunk at a
    /// time, remembered until the file changes (device, inode, size, modification date).
    func latestReading(in file: URL) -> UsageReading? {
        guard let identity = FileIdentity(file) else { return nil }
        if let known = memo.answer(for: file, identity: identity) { return known.reading }
        let reading = scanBackwards(file)
        memo.remember(file, identity: identity, reading: reading)
        return reading
    }

    private func scanBackwards(_ file: URL) -> UsageReading? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var end = (try? handle.seekToEnd()) ?? 0
        // Bytes after the last newline seen so far: the start of a line the next chunk completes.
        var carry = Data()
        while end > 0 {
            let start = end > UInt64(chunkBytes) ? end - UInt64(chunkBytes) : 0
            try? handle.seek(toOffset: start)
            guard var chunk = try? handle.read(upToCount: Int(end - start)) else { return nil }
            chunk.append(carry)
            if start > 0, let firstNewline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                // Everything before the first newline may be a partial line: keep it for later.
                carry = chunk.subdata(in: chunk.startIndex..<firstNewline)
                chunk = chunk.subdata(in: chunk.index(after: firstNewline)..<chunk.endIndex)
            } else if start > 0 {
                carry = chunk
                end = start
                continue
            } else {
                carry = Data()
            }
            if let reading = Self.latestReading(inLines: chunk) { return reading }
            end = start
        }
        return carry.isEmpty ? nil : Self.latestReading(inLines: carry)
    }

    /// What identifies a file's contents without reading them.
    struct FileIdentity: Equatable {
        var device: UInt64, inode: UInt64, size: UInt64, modified: Date

        init?(_ url: URL) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            device = (a[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            modified = a[.modificationDate] as? Date ?? .distantPast
        }
    }

    final class Memo: @unchecked Sendable {
        struct Entry { var identity: FileIdentity; var reading: UsageReading? }
        private var entries: [URL: Entry] = [:]
        private let lock = NSLock()
        /// How many files were read rather than remembered (tests).
        private(set) var scans = 0

        func answer(for url: URL, identity: FileIdentity) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[url], entry.identity == identity else { return nil }
            return entry
        }

        func remember(_ url: URL, identity: FileIdentity, reading: UsageReading?) {
            lock.lock(); defer { lock.unlock() }
            scans += 1
            entries[url] = Entry(identity: identity, reading: reading)
            if entries.count > 64 { entries = entries.filter { $0.key == url } }
        }

        var scanCount: Int { lock.lock(); defer { lock.unlock() }; return scans }
    }

    /// Scans JSON lines from the end for the newest record with a non-null `rate_limits`.
    public static func latestReading(inLines data: Data, partialFirstLine: Bool = false) -> UsageReading? {
        let marker = Data("\"rate_limits\"".utf8)
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if partialFirstLine, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard line.range(of: marker) != nil,
                  let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let reading = reading(fromRecord: record) else { continue }
            return reading
        }
        return nil
    }

    /// One record: `{"timestamp", "payload": {"rate_limits": {primary, secondary, credits,
    /// plan_type}}}`. `primary`/`secondary` are `{used_percent, window_minutes, resets_at}` with
    /// `resets_at` in unix seconds (older logs: `resets_in_seconds`, from the record's
    /// timestamp). Nil when `rate_limits` is null or has no window.
    public static func reading(fromRecord record: [String: Any]) -> UsageReading? {
        let payload = record["payload"] as? [String: Any]
        guard let limits = (payload?["rate_limits"] ?? record["rate_limits"]) as? [String: Any],
              let observed = PayloadValues.date(record["timestamp"]) else { return nil }
        let exhausted = limits["rate_limit_reached_type"] is String
        func shape(_ raw: Any?, _ fallbackID: String, _ fallbackSeconds: Int) -> UsageWindow? {
            guard let w = raw as? [String: Any] else { return nil }
            let minutes = PayloadValues.number(w["window_minutes"])
            return CodexUsage.window(usedPercent: w["used_percent"], seconds: minutes.map { Int($0 * 60) },
                                     resetsAt: PayloadValues.date(w["resets_at"])
                                        ?? PayloadValues.number(w["resets_in_seconds"]).map { observed.addingTimeInterval($0) },
                                     fallbackID: fallbackID, fallbackSeconds: fallbackSeconds, exhausted: exhausted)
        }
        let windows = CodexUsage.assemble(primary: shape(limits["primary"], "five_hour", 18000),
                                          secondary: shape(limits["secondary"], "seven_day", 604800))
        let credits = CodexUsage.credits(from: limits["credits"])
        guard windows != nil || credits != nil else { return nil }
        return UsageReading(windows: windows ?? [], credits: credits, plan: limits["plan_type"] as? String,
                            observedAt: observed, source: .sessionLog)
    }
}
