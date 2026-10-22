import Foundation

/// Helpers for very large JSON-lines files: find lines by a literal, then pull out only the
/// small pieces needed, instead of decoding whole lines that can be hundreds of kilobytes.
public enum JSONLScanner {
    /// Calls `body` with each complete line (newline excluded) and returns the number of bytes
    /// consumed, which ends after the last newline; a trailing partial line is left for later.
    @discardableResult
    public static func forEachLine(in data: Data, _ body: (Data) -> Void) -> Int {
        var consumed = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            let count = buffer.count
            while start < count {
                guard let found = memchr(base + start, 0x0A, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(found))
                if end > start {
                    body(data.subdata(in: data.startIndex + start..<data.startIndex + end))
                }
                start = end + 1
                consumed = start
            }
        }
        return consumed
    }

    /// Like `forEachLine`, but only hands over lines containing one of `markers`. The search
    /// runs over the whole buffer, so lines without a marker are never copied or examined;
    /// in transcripts that is most of the data.
    @discardableResult
    public static func forEachLine(containing markers: [String], in data: Data, _ body: (Data) -> Void) -> Int {
        let needles = markers.map { Array($0.utf8) }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress, let finalNewline = Self.lastNewline(in: base, before: buffer.count) else { return 0 }
            let end = finalNewline + 1
            var lines: [Range<Int>] = []
            for needle in needles {
                var offset = 0
                while offset < end, let hit = needle.withUnsafeBytes({ memmem(base + offset, end - offset, $0.baseAddress, needle.count) }) {
                    let position = base.distance(to: UnsafeRawPointer(hit))
                    let start = Self.lastNewline(in: base, before: position).map { $0 + 1 } ?? 0
                    let stop = memchr(base + position, 0x0A, end - position).map { base.distance(to: UnsafeRawPointer($0)) } ?? end
                    lines.append(start..<stop)
                    offset = stop + 1
                }
            }
            var seen = Set<Int>()
            for range in lines.sorted(by: { $0.lowerBound < $1.lowerBound }) where seen.insert(range.lowerBound).inserted {
                body(Data(buffer[range]))
            }
            return end
        }
    }

    /// The offset of the last newline before `position` (macOS has no memrchr).
    private static func lastNewline(in base: UnsafeRawPointer, before position: Int) -> Int? {
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var index = position - 1
        while index >= 0 {
            if bytes[index] == 0x0A { return index }
            index -= 1
        }
        return nil
    }

    public static func contains(_ line: Data, _ needle: String) -> Bool {
        range(of: Array(needle.utf8), in: line, last: false) != nil
    }

    /// The string after a literal marker such as `"aiTitle":"`, up to its closing quote,
    /// with JSON escapes decoded.
    public static func string(after marker: String, in line: Data, last: Bool = false) -> String? {
        guard let start = range(of: Array(marker.utf8), in: line, last: last)?.upperBound else { return nil }
        return line.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
            var index = start
            var escaped = false
            while index < buffer.count {
                let byte = buffer[index]
                if escaped {
                    escaped = false
                } else if byte == 0x5C {  // backslash
                    escaped = true
                } else if byte == 0x22 {  // closing quote
                    let raw = UnsafeRawBufferPointer(rebasing: buffer[start..<index])
                    // Most values have no escapes; only those need a JSON decoder.
                    guard raw.contains(0x5C) else { return String(decoding: raw, as: UTF8.self) }
                    let quoted = Data([0x22]) + Data(raw) + Data([0x22])
                    return (try? JSONDecoder().decode(String.self, from: quoted)) ?? String(decoding: raw, as: UTF8.self)
                }
                index += 1
            }
            return nil
        }
    }

    /// The JSON object that follows `"key":`, with its braces balanced, decoded as a dictionary.
    public static func object(forKey key: String, in line: Data, last: Bool = false) -> [String: Any]? {
        guard let start = range(of: Array("\"\(key)\":{".utf8), in: line, last: last)?.upperBound else { return nil }
        let open = start - 1
        return line.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [String: Any]? in
            var depth = 0
            var inString = false
            var escaped = false
            var index = open
            while index < buffer.count {
                let byte = buffer[index]
                if inString {
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B {
                    depth += 1
                } else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        let slice = Data(buffer[open...index])
                        return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
                    }
                }
                index += 1
            }
            return nil
        }
    }

    /// Byte offsets of the first (or last) occurrence of `needle`, using memmem.
    static func range(of needle: [UInt8], in data: Data, last: Bool) -> Range<Int>? {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Range<Int>? in
            guard let base = buffer.baseAddress, !needle.isEmpty, buffer.count >= needle.count else { return nil }
            var result: Range<Int>?
            var offset = 0
            while offset <= buffer.count - needle.count {
                guard let found = needle.withUnsafeBytes({ memmem(base + offset, buffer.count - offset, $0.baseAddress, needle.count) })
                else { break }
                let position = base.distance(to: UnsafeRawPointer(found))
                result = position..<position + needle.count
                if !last { break }
                offset = position + 1
            }
            return result
        }
    }
}
