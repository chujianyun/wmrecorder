import AVFoundation
import AppKit
import SwiftUI

final class CameraPreviewController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.wuming.wmrecorder.preview")
    func start(deviceID: String) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw RecorderError.message("请先允许摄像头权限。") }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video) else { throw RecorderError.message("没有可用的摄像头。") }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration(); session.sessionPreset = .high
        guard session.canAddInput(input) else { session.commitConfiguration(); throw RecorderError.message("摄像头无法启动。") }
        session.addInput(input); session.commitConfiguration()
        await withCheckedContinuation { continuation in queue.async { self.session.startRunning(); continuation.resume() } }
    }
    func stop() async { await withCheckedContinuation { continuation in queue.async { self.session.stopRunning(); continuation.resume() } } }
}
struct CameraLivePreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirror: Bool
    func makeNSView(context: Context) -> CameraLayerView { let view = CameraLayerView(); view.preview.session = session; return view }
    func updateNSView(_ view: CameraLayerView, context: Context) { view.preview.session = session; if let connection = view.preview.connection, connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = mirror } }
}
class CameraLayerView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer = CALayer(); layer?.backgroundColor = NSColor.black.cgColor; preview.videoGravity = .resizeAspect; layer?.addSublayer(preview) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() { super.layout(); preview.frame = bounds }
}
