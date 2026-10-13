import Foundation

/// How long a provider stays quiet after a failed read. Anthropic's usage endpoint answers 429
/// quota meter's pacing) and a `Retry-After` header wins when the provider sends one.
public enum Backoff {
    public static let base: TimeInterval = 120
    public static let maximum: TimeInterval = 30 * 60

    /// The wait after the `level`-th failure in a row (0 for the first).
    public static func delay(level: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, maximum) }
        let exponent = min(max(level, 0), 16)
        return min(base * pow(2, Double(exponent)), maximum)
    }

    /// A `Retry-After` value: delay seconds or an HTTP date. Nil when absent or unreadable.
    public static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds > 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value), date > now else { return nil }
        return date.timeIntervalSince(now)
    }
}

extension ProviderRecord {
    /// The record after a successful read.
    public func succeeded(with reading: UsageReading, at now: Date) -> ProviderRecord {
        ProviderRecord(reading: reading, lastAttemptAt: now, lastSuccessAt: now, problem: nil, backoffLevel: 0, retryAt: nil)
    }

    /// The record after a failed attempt: the last good reading is kept; a network-side
    /// problem advances the backoff, a local one (signed out, expired) does not.
    public func failed(_ problem: FetchProblem, at now: Date, retryAfter: TimeInterval? = nil) -> ProviderRecord {
        var next = self
        next.lastAttemptAt = now
        next.problem = problem
        if problem.backsOff {
            next.retryAt = now.addingTimeInterval(Backoff.delay(level: backoffLevel, retryAfter: retryAfter))
            next.backoffLevel = backoffLevel + 1
        } else {
            next.retryAt = nil
            next.backoffLevel = 0
        }
        return next
    }

    /// Whether a scheduled (not user-asked) attempt should wait: backing off, or tried less
    /// than `minimumSpacing` seconds ago.
    public func shouldWait(at now: Date, minimumSpacing: TimeInterval) -> Bool {
        if let retryAt, now < retryAt { return true }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < minimumSpacing { return true }
        return false
    }
}
