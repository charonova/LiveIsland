import Foundation

/// What's playing, from the media adapter's stream (one JSON object per line).
public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var bundleIdentifier: String?
    public var duration: Double?
    /// Position when `timestamp` was taken.
    public var elapsed: Double?
    public var timestamp: Date?
    public var playbackRate: Double
    public var isPlaying: Bool
    public var artwork: Data?
    /// The player's own id for the track ("spotify:track:…", a Music persistent ID), when known.
    public var trackID: String?

    public init(title: String, artist: String = "", album: String = "", bundleIdentifier: String? = nil,
                duration: Double? = nil, elapsed: Double? = nil, timestamp: Date? = nil, playbackRate: Double = 1,
                isPlaying: Bool = false, artwork: Data? = nil, trackID: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.bundleIdentifier = bundleIdentifier
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.artwork = artwork
        self.trackID = trackID
    }

    /// The current position, moving forward from the last report while playing.
    public func position(at now: Date) -> Double? {
        guard let elapsed else { return nil }
        var position = elapsed
        if isPlaying, let timestamp {
            position += now.timeIntervalSince(timestamp) * (playbackRate == 0 ? 1 : playbackRate)
        }
        if let duration, duration > 0 { position = min(position, duration) }
        return max(0, position)
    }

    public func progress(at now: Date) -> Double? {
        guard let duration, duration > 0, let position = position(at: now) else { return nil }
        return position / duration
    }

    /// Applies one stream line to the previous state. A diff line changes only the keys it
    /// contains; an empty full payload means nothing is playing. Lines that aren't data return
    /// the previous state unchanged.
    public static func applying(_ line: Data, to previous: NowPlaying?) -> NowPlaying? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any]
        else { return previous }
        let isDiff = object["diff"] as? Bool ?? false
        if !isDiff && payload.isEmpty { return nil }

        var info = isDiff ? (previous ?? NowPlaying(title: "")) : NowPlaying(title: "")
        func has(_ key: String) -> Bool { payload.keys.contains(key) }
        if has("title") { info.title = payload["title"] as? String ?? "" }
        if has("artist") { info.artist = payload["artist"] as? String ?? "" }
        if has("album") { info.album = payload["album"] as? String ?? "" }
        if has("bundleIdentifier") { info.bundleIdentifier = payload["bundleIdentifier"] as? String }
        if has("duration") { info.duration = (payload["duration"] as? NSNumber)?.doubleValue }
        if has("elapsedTime") { info.elapsed = (payload["elapsedTime"] as? NSNumber)?.doubleValue }
        if has("timestamp") { info.timestamp = (payload["timestamp"] as? String).flatMap(Format.date(iso8601:)) }
        if has("playbackRate") { info.playbackRate = (payload["playbackRate"] as? NSNumber)?.doubleValue ?? 1 }
        if has("playing") { info.isPlaying = payload["playing"] as? Bool ?? false }
        if has("artworkData") { info.artwork = (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) } }
        return info.title.isEmpty ? nil : info
    }
}
