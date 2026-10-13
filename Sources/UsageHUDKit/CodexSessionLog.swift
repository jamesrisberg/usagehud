import Foundation

/// The offline fallback for Codex: every Codex turn writes a `token_count` event with the
/// account's `rate_limits` into its session log (`<codex home>/sessions/YYYY/MM/DD/*.jsonl`).
/// The newest such record is the last reading Codex itself saw, shown with its age.
///
/// Only the `rate_limits` object and the record's timestamp are read; the rest of the log (the
/// conversation) is never decoded beyond finding that object.
public struct CodexSessionLog: Sendable {
    public let sessionsDirectory: URL
    /// How many of the newest log files to look through.
    public var fileLimit = 6
    /// How much of the end of each file to read first.
    public var tailBytes = 512 * 1024

    public init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    public init(codexHome: URL) {
        self.init(sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true))
    }

    /// The newest reading across the newest log files, or nil when none has one.
    public func latestReading() -> UsageReading? {
        var best: UsageReading?
        for file in newestFiles() {
            guard let reading = latestReading(in: file) else { continue }
            if best == nil || reading.observedAt > best!.observedAt { best = reading }
        }
        return best
    }

    /// The newest `.jsonl` files: the date directories are walked newest first (they are named
    /// by number), so a large history costs nothing.
    func newestFiles() -> [URL] {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                         options: [.skipsHiddenFiles])) ?? []
        }
        func numbered(_ url: URL) -> [URL] {
            children(url).filter { Int($0.lastPathComponent) != nil }
                .sorted { Int($0.lastPathComponent)! > Int($1.lastPathComponent)! }
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        var files: [URL] = []
        outer: for year in numbered(sessionsDirectory) {
            for month in numbered(year) {
                for day in numbered(month) {
                    let logs = children(day).filter { $0.pathExtension == "jsonl" }.sorted { modified($0) > modified($1) }
                    files.append(contentsOf: logs)
                    // A day can hold an older session that was written to most recently, so a
                    // whole day is taken before stopping.
                    if files.count >= fileLimit { break outer }
                }
            }
        }
        // Files directly in sessions/ (older layouts).
        files.append(contentsOf: children(sessionsDirectory).filter { $0.pathExtension == "jsonl" })
        return Array(files.sorted { modified($0) > modified($1) }.prefix(fileLimit))
    }

    /// The last record with a `rate_limits` object in one file: its tail first, the whole file
    /// when the tail has none.
    func latestReading(in file: URL) -> UsageReading? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        if let tail = try? handle.readToEnd(), let reading = Self.latestReading(inLines: tail, partialFirstLine: start > 0) {
            return reading
        }
        guard start > 0, size <= 64 * 1024 * 1024 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let whole = try? handle.readToEnd() else { return nil }
        return Self.latestReading(inLines: whole, partialFirstLine: false)
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
    /// `resets_at` in unix seconds. Nil when `rate_limits` is null or has no window.
    public static func reading(fromRecord record: [String: Any]) -> UsageReading? {
        let payload = record["payload"] as? [String: Any]
        guard let limits = (payload?["rate_limits"] ?? record["rate_limits"]) as? [String: Any],
              let observed = PayloadValues.date(record["timestamp"]) else { return nil }
        let exhausted = limits["rate_limit_reached_type"] is String
        func shape(_ raw: Any?, _ fallbackID: String, _ fallbackSeconds: Int) -> UsageWindow? {
            guard let w = raw as? [String: Any] else { return nil }
            let minutes = PayloadValues.number(w["window_minutes"])
            return CodexUsage.window(usedPercent: w["used_percent"], seconds: minutes.map { Int($0 * 60) },
                                     resetsAt: PayloadValues.date(w["resets_at"]),
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
