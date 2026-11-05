import Foundation

public enum SetupStep: CaseIterable, Sendable {
    case applications, camera, approveExtension, callApp
}

public enum CameraAccess: Sendable {
    case notAsked, denied, granted
}

public struct SetupFacts: Equatable, Sendable {
    public var inApplications: Bool
    public var camera: CameraAccess
    public var extensionActive: Bool
    public var hasSeenClient: Bool

    public init(inApplications: Bool, camera: CameraAccess, extensionActive: Bool, hasSeenClient: Bool) {
        self.inApplications = inApplications
        self.camera = camera
        self.extensionActive = extensionActive
        self.hasSeenClient = hasSeenClient
    }
}

/// What the first-run window shows. Steps can finish in any order.
public struct SetupState: Sendable {
    private let facts: SetupFacts

    public init(_ facts: SetupFacts) {
        self.facts = facts
    }

    public func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .applications: facts.inApplications
        case .camera: facts.camera == .granted
        case .approveExtension: facts.extensionActive
        case .callApp: facts.hasSeenClient
        }
    }

    /// macOS refuses a system extension from outside Applications, and a call app has nothing to pick until the rest is done.
    public func isEnabled(_ step: SetupStep) -> Bool {
        switch step {
        case .applications, .camera: true
        case .approveExtension: isDone(.applications)
        case .callApp: isDone(.applications) && isDone(.camera) && isDone(.approveExtension)
        }
    }

    public var currentStep: SetupStep? {
        SetupStep.allCases.first { !isDone($0) }
    }

    public var isComplete: Bool {
        currentStep == nil
    }

    /// Outside Applications it always opens. Otherwise only until setup has finished once.
    public func opensAtLaunch(finishedBefore: Bool) -> Bool {
        !facts.inApplications || (!finishedBefore && !isComplete)
    }
}

/// What to do when the extension is approved and its camera device isn't there.
public enum DeviceRecovery: Equatable, Sendable {
    case wait, relaunch, askForRestart

    /// A running app's view of the device list can go stale after a replacement, and only a fresh process sees past
    /// that, so it relaunches once. If the device is still missing, macOS isn't running the extension.
    /// The wait starts from whichever came later, so a person slowly approving in Settings doesn't count against it.
    public static func next(missingSince: Date?, activeSince: Date?, now: Date, alreadyRelaunched: Bool,
                            wait: TimeInterval = 20) -> DeviceRecovery {
        guard let missingSince, let activeSince,
              now.timeIntervalSince(max(missingSince, activeSince)) >= wait else { return .wait }
        return alreadyRelaunched ? .askForRestart : .relaunch
    }
}
