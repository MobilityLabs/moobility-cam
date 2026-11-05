import AVFoundation
import MoobilityCore
import SwiftUI

/// Mirrored raw preview, a 3 s countdown, and recording up to 5 minutes. What a call sees doesn't change.
struct RecordSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                CameraPreview(session: model.captureSession)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                if let count = model.recordingCountdown {
                    Text("\(count)")
                        .font(.system(size: 96, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                }
                if let problem = model.recordProblem {
                    Text(problem)
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                if model.isRecording {
                    Label(ClipTime.text(model.recordingElapsed.rounded(.down)), systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .monospacedDigit()
                    Text("of 5:00").foregroundStyle(.secondary)
                } else {
                    Text(model.clipMessage ?? "Clips stay on this Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isRecording ? "Done" : "Close") { model.closeRecordSheet() }
                    .keyboardShortcut(.cancelAction)
                if !model.isRecording {
                    Button("Start") { model.beginCountdown() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canRecord || model.recordingCountdown != nil)
                } else {
                    Button("Stop") { model.stopRecording() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 640)
    }

}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
