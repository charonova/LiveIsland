import Foundation

/// Short, glanceable text for a space as small as a notch.
public enum Format {
    /// 950, 12.4K, 3.2M, 1.1B
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return trimmed(value / 1_000) + "K"
        case ..<1_000_000_000: return trimmed(value / 1_000_000) + "M"
        default: return trimmed(value / 1_000_000_000) + "B"
        }
    }

    /// 0:42, 12:05, 1:02:05
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// 45s, 12m, 1h 5m, 2d 4h
    public static func span(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        switch total {
        case ..<60: return "\(total)s"
        case ..<3600: return "\(total / 60)m"
        case ..<86_400:
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
        default:
            let hours = (total % 86_400) / 3600
            return hours == 0 ? "\(total / 86_400)d" : "\(total / 86_400)d \(hours)h"
        }
    }

    /// "in 3h 12m", or "now" once the moment has passed.
    public static func until(_ date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        return seconds <= 0 ? "now" : "in " + span(seconds)
    }

    public static func date(iso8601 text: String) -> Date? {
        utcTimestamp(text) ?? fractional.date(from: text) ?? plain.date(from: text)
    }

    /// Fast path for the "2026-10-22T13:52:07.633Z" form every transcript line carries;
    /// ISO8601DateFormatter is far too slow for hundreds of thousands of lines.
    static func utcTimestamp(_ text: String) -> Date? {
        var utf8 = text.utf8.makeIterator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        while let byte = utf8.next(), bytes.count < 40 { bytes.append(byte) }
        guard bytes.count >= 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
              bytes[13] == 0x3A, bytes[16] == 0x3A else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var index = 19
        var fraction = 0.0
        if bytes[index] == 0x2E {  // .
            index += 1
            var scale = 0.1
            while index < bytes.count, (48...57).contains(bytes[index]) {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        guard index == bytes.count - 1, bytes[index] == 0x5A else { return nil }  // Z, nothing after
        // Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    private static func trimmed(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()
}
