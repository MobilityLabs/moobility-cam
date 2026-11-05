import Foundation

/// Decides whether the app should register itself as a login item. Only a copy installed
/// in /Applications is ever registered, so a Debug build or a copy still inside a mounted
/// DMG never becomes the login item.
public enum LoginItemPolicy {
    public enum State: Sendable {
        case enabled, notRegistered, notFound, requiresApproval
    }

    public static func shouldRegister(_ state: State, userOptedOut: Bool, bundlePath: String) -> Bool {
        guard !userOptedOut, bundlePath.hasPrefix("/Applications/") else { return false }
        switch state {
        case .notRegistered, .notFound: return true
        case .enabled, .requiresApproval: return false
        }
    }
}
