import Foundation

/// A global shortcut, in Carbon's key code and modifier values.
public struct HotKeyCombo: Equatable, Sendable {
    private static let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096

    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public static let `default` = HotKeyCombo(keyCode: 15, carbonModifiers: cmd | option | control)!  // ⌃⌥⌘R

    /// nil without one of ⌘ ⌃ ⌥: a plain or shift-only key would fire while typing.
    public init?(keyCode: UInt32, carbonModifiers: UInt32) {
        guard carbonModifiers & (Self.cmd | Self.option | Self.control) != 0 else { return nil }
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    public init?(stored: String) {
        let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let key = UInt32(parts[0]), let modifiers = UInt32(parts[1]) else { return nil }
        self.init(keyCode: key, carbonModifiers: modifiers)
    }

    public var stored: String { "\(keyCode):\(carbonModifiers)" }

    public var display: String {
        var text = ""
        if carbonModifiers & Self.control != 0 { text += "⌃" }
        if carbonModifiers & Self.option != 0 { text += "⌥" }
        if carbonModifiers & Self.shift != 0 { text += "⇧" }
        if carbonModifiers & Self.cmd != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 49: "Space",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1",
    ]
}
