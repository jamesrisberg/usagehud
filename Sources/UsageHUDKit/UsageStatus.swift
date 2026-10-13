import Foundation

/// What the panel says about one provider, derived from its record and the clock.
public enum UsageStatus: Equatable, Sendable {
    /// Turned off in settings.
    case off
    /// No reading yet and nothing has gone wrong: the first read is on its way.
    case loading
    /// A reading from the endpoint, from the last attempt, younger than the stale limit.
    case live
    /// A reading that is old, from the session log, or kept after a failed attempt.
    case stale(age: TimeInterval)
    /// No reading, and the owner has to sign in (or allow access) first.
    case signedOut
    /// No reading, and the last attempt failed.
    case error

    public var code: String {
        switch self {
        case .off: return "off"
        case .loading: return "loading"
        case .live: return "live"
        case .stale: return "stale"
        case .signedOut: return "signedOut"
        case .error: return "error"
        }
    }

    /// A reading older than this is stale even when the last attempt succeeded: two poll
    /// intervals and a minute, so one late poll does not flip it.
    public static func staleAfter(pollMinutes: Int) -> TimeInterval {
        TimeInterval(max(pollMinutes, 1) * 2 * 60 + 60)
    }

    public static func of(_ record: ProviderRecord?, enabled: Bool, now: Date, staleAfter: TimeInterval) -> UsageStatus {
        guard enabled else { return .off }
        let record = record ?? ProviderRecord()
        guard let reading = record.reading else {
            guard let problem = record.problem else { return .loading }
            return problem.needsSignIn ? .signedOut : .error
        }
        let age = max(0, now.timeIntervalSince(reading.observedAt))
        if record.problem == nil, reading.source == .live, age <= staleAfter { return .live }
        return .stale(age: age)
    }
}

/// The panel's words for durations, ages and percentages.
public enum UsageFormat {
    /// The largest two non-zero units, never seconds: `2h 13m`, `3d 4h`, `<1m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "<1m" }
        var rest = Int(seconds)
        var parts: [String] = []
        for (suffix, size) in [("d", 86400), ("h", 3600), ("m", 60)] {
            let count = rest / size
            rest -= count * size
            if count > 0 { parts.append("\(count)\(suffix)") }
            if parts.count == 2 { break }
        }
        return parts.isEmpty ? "<1m" : parts.joined(separator: " ")
    }

    /// `resets in 2h 13m`; once the instant has passed, the old number no longer holds:
    /// `reset, waiting for a new reading`.
    public static func resets(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let left = date.timeIntervalSince(now)
        return left <= 0 ? "reset, waiting for a new reading" : "resets in \(duration(left))"
    }

    /// `just now`, `3m ago`, `2h 5m ago`.
    public static func age(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "just now" : "\(duration(seconds)) ago"
    }

    /// `42%`; `<1%` for a sliver; `—` without a number.
    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value > 0, value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// `62,500` (no decimals once it is above 100).
    public static func credits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// `max` → `Max`, `pro` → `Pro`, `team` → `Team`.
    public static func plan(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
