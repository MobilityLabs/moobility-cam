import Foundation

/// What the virtual camera sends out.
public enum CameraMode: String, CaseIterable, Sendable {
    case overBackground, plainCamera, backgroundOnly

    /// Whether sending this mode needs the webcam. Only background-only output doesn't. The Record sheet can hold it on regardless.
    public var needsCamera: Bool {
        self != .backgroundOnly
    }

    public var title: String {
        switch self {
        case .overBackground: "Me over background"
        case .plainCamera: "Plain camera"
        case .backgroundOnly: "Background only"
        }
    }
}
