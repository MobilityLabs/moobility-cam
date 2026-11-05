import Foundation

/// What the hotkey plays.
public enum ReplayTarget: Equatable, Hashable, Sendable {
    case last(seconds: Int)
    case clip(file: String)

    private static let presetSeconds = [15, 30, 60, 120, 300]
    public static let presets: [ReplayTarget] = presetSeconds.map { .last(seconds: $0) }
    public static let `default`: ReplayTarget = .last(seconds: 60)

    public init?(stored: String) {
        if stored.hasPrefix("last:"), let seconds = Int(stored.dropFirst(5)), Self.presetSeconds.contains(seconds) {
            self = .last(seconds: seconds)
        } else if stored.hasPrefix("clip:") {
            let file = String(stored.dropFirst(5))
            guard !file.isEmpty, !file.contains("/"), !file.hasPrefix(".") else { return nil }
            self = .clip(file: file)
        } else {
            return nil
        }
    }

    public var stored: String {
        switch self {
        case .last(let seconds): "last:\(seconds)"
        case .clip(let file): "clip:\(file)"
        }
    }

    public var title: String {
        switch self {
        case .last(let seconds):
            if seconds < 60 { return "Last \(seconds) seconds" }
            let minutes = seconds / 60
            return minutes == 1 ? "Last 1 minute" : "Last \(minutes) minutes"
        case .clip(let file):
            return file.hasSuffix(".mov") ? String(file.dropLast(4)) : file
        }
    }
}

public enum ReplayRefusal: Equatable, Sendable {
    case noApp, recordSheetOpen, recentVideoOff, backgroundOnly, notEnoughVideo, badFile, clipTooLong

    public var message: String {
        switch self {
        case .noApp: "No app is using Moobility Cam"
        case .recordSheetOpen: "Close the Record window first"
        case .recentVideoOff: "Recent video is off"
        case .backgroundOnly: "No recent video in Background only"
        case .notEnoughVideo: "Not enough recent video yet"
        case .badFile: "Can't play this clip"
        case .clipTooLong: "Clip is longer than 5 minutes"
        }
    }
}

public struct ReplayConditions: Sendable {
    public var hasClient: Bool
    public var recordSheetOpen: Bool
    public var recentVideoOn: Bool
    public var mode: CameraMode
    public var heldSeconds: Double

    public init(hasClient: Bool, recordSheetOpen: Bool, recentVideoOn: Bool, mode: CameraMode, heldSeconds: Double) {
        self.hasClient = hasClient
        self.recordSheetOpen = recordSheetOpen
        self.recentVideoOn = recentVideoOn
        self.mode = mode
        self.heldSeconds = heldSeconds
    }
}

public enum ReplayRules {
    /// nil means start. A saved clip's own problems are only known once it's read.
    public static func refusal(for target: ReplayTarget, given c: ReplayConditions) -> ReplayRefusal? {
        if !c.hasClient { return .noApp }
        if c.recordSheetOpen { return .recordSheetOpen }
        guard case .last = target else { return nil }
        if !c.recentVideoOn { return .recentVideoOff }
        if c.mode == .backgroundOnly { return .backgroundOnly }
        if c.heldSeconds < ReplayConstants.minLength { return .notEnoughVideo }
        return nil
    }

    /// Recording alone never fills recent video.
    public static func holdsRecentVideo(hasClient: Bool, toggle: Bool, mode: CameraMode) -> Bool {
        hasClient && toggle && mode.needsCamera
    }
}

public enum ReplayEnd: Sendable {
    case goLive, modeChanged, sourceChanged, clientLost, sinkFailed
}

/// Replay's state. Every transition happens on the main actor; frame work is handed to the sink queue.
public struct ReplayMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// `replacing` is the target still playing while this one loads, so a switch never shows live video.
        case loading(requestID: Int, target: ReplayTarget, replacing: ReplayTarget?)
        case playing(target: ReplayTarget)
    }

    public private(set) var state: State = .idle
    private var lastRequestID = 0

    public init() {}

    public var isActive: Bool { state != .idle }

    public var isOutputReplay: Bool {
        switch state {
        case .idle: false
        case .loading(_, _, let replacing): replacing != nil
        case .playing: true
        }
    }

    /// From any state; replaces any load. Returns the new request ID.
    public mutating func begin(_ target: ReplayTarget) -> Int {
        let replacing: ReplayTarget?
        switch state {
        case .idle: replacing = nil
        case .loading(_, _, let current): replacing = current
        case .playing(let current): replacing = current
        }
        lastRequestID += 1
        state = .loading(requestID: lastRequestID, target: target, replacing: replacing)
        return lastRequestID
    }

    /// True when this was the current request: now playing.
    public mutating func loadFinished(requestID: Int) -> Bool {
        guard case .loading(requestID, let target, _) = state else { return false }
        state = .playing(target: target)
        return true
    }

    /// True when this was the current request: back to the replaced target if there was one, else idle.
    public mutating func loadFailed(requestID: Int) -> Bool {
        guard case .loading(requestID, _, let replacing) = state else { return false }
        state = replacing.map { .playing(target: $0) } ?? .idle
        return true
    }

    /// Back to idle. Returns whether output should fade: only when output was replay, and not for client loss or sink failure.
    public mutating func end(_ reason: ReplayEnd) -> Bool {
        let wasReplay = isOutputReplay
        state = .idle
        switch reason {
        case .clientLost, .sinkFailed: return false
        case .goLive, .modeChanged, .sourceChanged: return wasReplay
        }
    }

    /// The clip keeps its place under its new name.
    public mutating func clipRenamed(from old: String, to new: String) {
        func renamed(_ target: ReplayTarget) -> ReplayTarget { target == .clip(file: old) ? .clip(file: new) : target }
        switch state {
        case .idle: break
        case .loading(let id, let target, let replacing):
            state = .loading(requestID: id, target: renamed(target), replacing: replacing.map(renamed))
        case .playing(let target):
            state = .playing(target: renamed(target))
        }
    }

    /// Cancels a load of that clip, same as a failed load; a playing clip continues.
    public mutating func clipRemoved(file: String) {
        if case .loading(let id, .clip(file), _) = state {
            _ = loadFailed(requestID: id)
        }
    }
}
