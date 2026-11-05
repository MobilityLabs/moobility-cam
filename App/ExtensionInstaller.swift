import Foundation
import os
import SystemExtensions

/// Submits the camera-extension activation request and tracks its outcome.
@MainActor final class ExtensionInstaller: NSObject, ObservableObject {
    enum Status: Equatable { case unknown, needsApproval, needsRestart, active, failed(String) }

    static let extensionID = "com.mobilitylabs.MoobilityCam.Extension"
    @Published private(set) var status: Status = .unknown
    var onActivated: (() -> Void)?
    private let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam", category: "Installer")

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    fileprivate func update(_ status: Status) {
        self.status = status
        switch status {
        case .active: onActivated?()
        case .failed(let reason): log.error("activation failed: \(reason, privacy: .public)")
        default: break
        }
    }
}

extension ExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { update(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            update(result == .completed ? .active : .needsRestart)  // .willCompleteAfterReboot
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated { update(.failed(error.localizedDescription)) }
    }
}
