import Foundation

/// Lenient readers for the providers' JSON values, shared by the normalizers.
enum PayloadValues {
    /// A percentage clamped to 0-100; nil for anything that is not a finite number.
    static func percent(_ value: Any?) -> Double? {
        guard let number = self.number(value), number.isFinite else { return nil }
        return min(100, max(0, number))
    }

    /// A JSON number, or a decimal string (`"62500.0000000000"`).
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A reset instant: an ISO 8601 string (any number of fractional digits), unix seconds, or
    /// unix milliseconds. Nil for anything else, zero or negative.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if let date = iso8601(trimmed) { return date }
            if let seconds = Double(trimmed) { return epoch(seconds) }
            return nil
        }
        if let seconds = number(value) { return epoch(seconds) }
        return nil
    }

    private static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        // Below 1e11 it is seconds (unambiguous until the year 5138), otherwise milliseconds.
        return Date(timeIntervalSince1970: value < 1e11 ? value : value / 1000)
    }

    /// ISO 8601 with or without fractional seconds; the fraction may have any number of digits
    /// (Anthropic sends six), which `ISO8601DateFormatter` alone does not accept.
    static func iso8601(_ string: String) -> Date? {
        guard string.count >= 10, string.first?.isNumber == true else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        // Pull the fraction out, parse the rest, add the fraction back.
        guard let dot = string.firstIndex(of: "."), string.distance(from: string.startIndex, to: dot) >= 19 else { return nil }
        let afterDot = string.index(after: dot)
        let digitsEnd = string[afterDot...].firstIndex(where: { !$0.isNumber }) ?? string.endIndex
        let digits = string[afterDot..<digitsEnd]
        guard !digits.isEmpty, let fraction = Double("0." + digits) else { return nil }
        let rest = String(string[..<dot]) + String(string[digitsEnd...])
        guard let whole = plain.date(from: rest) else { return nil }
        return whole.addingTimeInterval(fraction)
    }
}
