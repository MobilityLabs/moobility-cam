import Foundation

/// What one output tick should do.
public struct ReplayStep: Equatable, Sendable {
    public let frameIndex: Int
    /// Frames to decode this tick, in order; nil when the frame hasn't changed.
    public let decode: ClosedRange<Int>?
    /// Playback passed the end of the footage and started over.
    public let wrapped: Bool
    /// This step crossed the loop end or a run start, or skipped ahead; start a fade.
    public let crossedSeam: Bool

    public init(frameIndex: Int, decode: ClosedRange<Int>?, wrapped: Bool, crossedSeam: Bool) {
        self.frameIndex = frameIndex
        self.decode = decode
        self.wrapped = wrapped
        self.crossedSeam = crossedSeam
    }
}

/// Maps elapsed time to frames of a looping list of frames, without ever asking for more decoding
/// in one tick than the budget, so catching up after a sleep can't hold the output queue.
public struct ReplayCursor: Sendable {
    public static let decodeBudget = 8

    private let starts: [Double]
    private let runStarts: Set<Int>
    private let keyframes: [Int]  // sorted
    public let totalDuration: Double

    private var lastDecoded: Int?
    private var loop = 0

    /// `durations` is non-empty and frame 0 is a keyframe.
    public init(durations: [Double], runStarts: Set<Int>, keyframes: Set<Int>) {
        var starts: [Double] = []
        starts.reserveCapacity(durations.count)
        var time = 0.0
        for duration in durations {
            starts.append(time)
            time += duration
        }
        self.starts = starts
        self.totalDuration = time
        self.runStarts = runStarts
        self.keyframes = keyframes.union([0]).sorted()
    }

    public mutating func advance(toElapsed elapsed: Double) -> ReplayStep {
        let time = max(elapsed, 0)
        let currentLoop = Int(time / totalDuration)
        let target = frame(at: time - Double(currentLoop) * totalDuration)
        let wrapped = currentLoop > loop
        if wrapped {
            loop = currentLoop
            lastDecoded = nil
        }

        let next = (lastDecoded ?? -1) + 1
        guard target >= next else {
            return ReplayStep(frameIndex: lastDecoded ?? target, decode: nil, wrapped: false, crossedSeam: false)
        }

        var start = next
        var skipped = false
        if target - next + 1 > Self.decodeBudget {
            let keyframe = nearestKeyframe(atOrBefore: target)
            if keyframe > next {
                start = keyframe
                skipped = true
            }
        }
        let end = min(start + Self.decodeBudget - 1, target)
        lastDecoded = end

        let firstEverFrame = !wrapped && next == 0
        let crossedRun = (start...end).contains { $0 != 0 && runStarts.contains($0) } && !firstEverFrame
        return ReplayStep(frameIndex: end, decode: start...end, wrapped: wrapped,
                          crossedSeam: wrapped || skipped || crossedRun)
    }

    private func frame(at time: Double) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func nearestKeyframe(atOrBefore index: Int) -> Int {
        var low = 0, high = keyframes.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if keyframes[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return keyframes[low]
    }
}

/// The first host time it's given is elapsed 0, so a replay always starts on its first frame.
public struct ReplayClock: Sendable {
    private var origin: Double?

    public init() {}

    public mutating func elapsed(at hostTime: Double) -> Double {
        if let origin { return hostTime - origin }
        origin = hostTime
        return 0
    }
}

/// How far a fade has got: 0 at its start, linear, 1 from `start + length` on.
public struct ReplayFade: Sendable {
    private let start: Double
    private let length: Double

    public init(start: Double, length: Double = ReplayConstants.fadeLength) {
        self.start = start
        self.length = length
    }

    public func mix(at time: Double) -> Double {
        min(max((time - start) / length, 0), 1)
    }

    public func isDone(at time: Double) -> Bool {
        mix(at: time) >= 1
    }
}
