import Foundation

/// Decides which copy of the app stays when more than one is running, because a second copy
/// would delete the first one's part files at launch.
public enum SingleInstance {
    public struct Running: Sendable {
        public let pid: Int32
        public let launched: Date?

        public init(pid: Int32, launched: Date?) {
            self.pid = pid
            self.launched = launched
        }
    }

    /// True when another running copy is older; ties go to the lower pid.
    public static func shouldQuit(me: Running, others: [Running]) -> Bool {
        others.contains { other in
            if let mine = me.launched, let theirs = other.launched, mine != theirs {
                return theirs < mine
            }
            return other.pid < me.pid
        }
    }
}
