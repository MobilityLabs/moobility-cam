import MoobilityCore
import SwiftUI

/// The first-run steps, each with live status and one action. Reopened from the menu's Setup… item.
struct SetupWindow: View {
    @ObservedObject var model: AppModel
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let cameraSettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    private static let extensionSettings = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    var body: some View {
        let state = SetupState(model.setupFacts)
        VStack(alignment: .leading, spacing: 16) {
            Text(state.isComplete ? "You're all set." : "A few steps and you'll be on camera over a cow office.")
                .font(.headline)
            row(.applications, "Move to Applications", "macOS only runs camera extensions from there.", state) {
                if model.setupRevealPath != nil || model.setupMessage != nil {
                    Button("Show in Finder") { model.revealForDragging() }
                }
                Button(model.isMoving ? "Moving…" : "Move and relaunch") { model.moveToApplications() }
                    .disabled(model.isMoving)
            }
            row(.camera, "Allow the camera", "It puts you over your background. Video stays on this Mac.", state) {
                if model.cameraAccess == .denied {
                    Button("Open Settings") { model.openSettings(Self.cameraSettings) }
                } else {
                    Button("Allow") { model.allowCamera() }
                }
            }
            row(.approveExtension, "Approve the camera extension", extensionDetail, state) {
                Button("Open Settings") { model.openSettings(Self.extensionSettings) }
            }
            row(.callApp, "Pick it in your call app", "Choose \"Moobility Cam\" in the app's camera settings.", state) {
                EmptyView()
            }
            if let message = model.setupMessage {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onReceive(tick) { _ in model.refreshCameraAccess() }
    }

    private var extensionDetail: String {
        if case .failed(let reason) = model.installer.status { return reason }
        if model.installer.status == .needsRestart { return "Restart your Mac to finish updating the camera." }
        return "Turn on Moobility Cam under Camera Extensions in System Settings."
    }

    private func row<Actions: View>(_ step: SetupStep, _ title: String, _ detail: String, _ state: SetupState,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        let done = state.isDone(step)
        let enabled = state.isEnabled(step)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(step == state.currentStep ? .semibold : .regular)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { HStack { actions() }.disabled(!enabled) }
        }
        .opacity(enabled || done ? 1 : 0.5)
    }
}
