import Foundation

public enum ReplayConstants {
    public static let maxLength = 300.0
    public static let minLength = 3.0
    public static let fadeLength = 0.5
    public static let countdown = 3.0
    public static let maxBytes = 256 * 1024 * 1024
    public static let bitRate = 3_000_000
    /// The last frame's own duration can end a full-length clip just past 300 s.
    public static let readSlack = 0.1
    static let provisionalDuration = 1.0 / 30
    static let durationLimits = (1.0 / 120)...0.1
}

/// One encoded frame and how long it shows.
public struct TimedFrame<Payload> {
    public let payload: Payload
    public var duration: Double
    public let isKeyframe: Bool
    public let startsRun: Bool
    public let byteCount: Int

    public init(payload: Payload, duration: Double, isKeyframe: Bool, startsRun: Bool, byteCount: Int) {
        self.payload = payload
        self.duration = duration
        self.isKeyframe = isKeyframe
        self.startsRun = startsRun
        self.byteCount = byteCount
    }
}

extension TimedFrame: Sendable where Payload: Sendable {}

/// The rolling store of recent frames. It always starts on a keyframe, and a frame's duration is
/// the gap to the next frame in its run, so a break in capture doesn't count as footage.
public struct RecentVideo<Payload> {
    private let maxDuration: Double
    private let maxBytes: Int
    private var lastCaptureTime: Double?

    public private(set) var frames: [TimedFrame<Payload>] = []
    public private(set) var totalDuration: Double = 0
    public private(set) var totalBytes: Int = 0

    public init(maxDuration: Double = ReplayConstants.maxLength, maxBytes: Int = ReplayConstants.maxBytes) {
        self.maxDuration = maxDuration
        self.maxBytes = maxBytes
    }

    public mutating func append(_ payload: Payload, captureTime: Double, isKeyframe: Bool, startsRun: Bool, byteCount: Int) {
        if !startsRun, let previous = lastCaptureTime, let last = frames.indices.last {
            let limits = ReplayConstants.durationLimits
            let gap = min(max(captureTime - previous, limits.lowerBound), limits.upperBound)
            totalDuration += gap - frames[last].duration
            frames[last].duration = gap
        }
        let duration = ReplayConstants.provisionalDuration
        frames.append(TimedFrame(payload: payload, duration: duration, isKeyframe: isKeyframe,
                                 startsRun: startsRun, byteCount: byteCount))
        totalDuration += duration
        totalBytes += byteCount
        lastCaptureTime = captureTime
        trim()
    }

    /// Newest frames covering `seconds`, starting at the keyframe at or before that point; everything held if shorter.
    public func window(last seconds: Double) -> [TimedFrame<Payload>] {
        var covered = 0.0
        var start = frames.endIndex
        while start > frames.startIndex, covered < seconds {
            start -= 1
            covered += frames[start].duration
        }
        while start > frames.startIndex, !frames[start].isKeyframe {
            start -= 1
        }
        return Array(frames[start...])
    }

    public mutating func removeAll() {
        frames.removeAll()
        totalDuration = 0
        totalBytes = 0
        lastCaptureTime = nil
    }

    private mutating func trim() {
        var drop = 0
        var duration = totalDuration
        var bytes = totalBytes
        while duration > maxDuration || bytes > maxBytes {
            var next = drop + 1
            while next < frames.count, !frames[next].isKeyframe { next += 1 }
            guard next < frames.count else { break }
            for frame in frames[drop..<next] {
                duration -= frame.duration
                bytes -= frame.byteCount
            }
            drop = next
        }
        if drop > 0 {
            frames.removeFirst(drop)
            totalDuration = duration
            totalBytes = bytes
        }
    }
}
