import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreImage
import AppKit

/// All mutable writer state is isolated to queue. Screen and camera callbacks share it.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.wuming.wmrecorder.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var session: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var cameraFrame: CVPixelBuffer?
    private var options = RecordingOptions()
    private var started = false
    private var paused = false
    private var pauseHost: CMTime?
    private var removedTime = CMTime.zero
    private var firstTime: CMTime?
    private var lastVideoTime: CMTime?
    private var accepting = false
    private var counts = ["video": 0, "system": 0, "microphone": 0, "camera": 0, "dropped": 0]
    private var failure: Error?
    var onFailure: (@Sendable (String) -> Void)?
    var onCameraSignal: (@Sendable (Bool) -> Void)?
    var onPreview: (@Sendable (CGImage) -> Void)?
    private var lastPreview = Date.distantPast
    var onLevels: (@Sendable (Float, Float) -> Void)?
    private var lastMeter = Date.distantPast
    private var systemLevel: Float = 0
    private var micLevel: Float = 0
    var cameraSession: AVCaptureSession? { session }

    func start(options: RecordingOptions, rawURL: URL) async throws {
        try options.validate()
        self.options = options
        if options.needsScreen && !CGPreflightScreenCaptureAccess() { throw RecorderError.message("请先在授权页面开启屏幕与系统音频录制权限。") }
        if options.microphone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { throw RecorderError.message("请先允许麦克风权限。") }
        if (options.mode == .camera || options.pictureInPicture) && AVCaptureDevice.authorizationStatus(for: .video) != .authorized { throw RecorderError.message("请先允许摄像头权限。") }
        do {
            try prepareWriter(rawURL)
            if options.mode == .camera || options.pictureInPicture || options.microphone && !options.needsScreen { try prepareSession() }
            accepting = true
            if session != nil { await withCheckedContinuation { continuation in queue.async { self.session?.startRunning(); continuation.resume() } } }
            if options.needsScreen { try await prepareStream() }
            var ready = false
            for _ in 0..<60 {
                ready = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.started) } }
                if ready { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard ready else { throw RecorderError.message("录制源在 6 秒内没有提供数据，请检查设备和权限。") }
        } catch {
            accepting = false
            session?.stopRunning()
            session = nil
            await releaseStream()
            writer?.cancelWriting()
            throw error
        }
    }
    private func prepareWriter(_ url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        self.writer = writer
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        if options.wantsVideo {
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: options.width, AVVideoHeightKey: options.height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: options.quality.bitrate, AVVideoExpectedSourceFrameRateKey: options.fps, AVVideoMaxKeyFrameIntervalKey: options.fps * 2]])
            video.expectsMediaDataInRealTime = true
            guard writer.canAdd(video) else { throw RecorderError.message("无法创建视频编码器。") }
            writer.add(video); videoInput = video
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: options.width, kCVPixelBufferHeightKey as String: options.height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        }
        if options.systemAudio { systemInput = try audioInput(writer, name: "System Audio") }
        if options.microphone { micInput = try audioInput(writer, name: "Microphone") }
        guard writer.startWriting() else { throw writer.error ?? RecorderError.message("无法开始写入媒体。") }
    }
    private func audioInput(_ writer: AVAssetWriter, name: String) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
        input.expectsMediaDataInRealTime = true
        let title = AVMutableMetadataItem(); title.identifier = .commonIdentifierTitle; title.value = name as NSString; input.metadata = [title]
        guard writer.canAdd(input) else { throw RecorderError.message("无法创建音频编码器。") }
        writer.add(input)
        return input
    }
    private func prepareSession() throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        if options.mode == .camera || options.pictureInPicture {
            let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
            guard let device = cameras.first(where: { $0.uniqueID == options.cameraID }) ?? AVCaptureDevice.default(for: .video) else { throw RecorderError.message("未找到可用摄像头。") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError.message("摄像头正在被占用。") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw RecorderError.message("无法添加摄像头输出。") }
            session.addOutput(output)
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
            try device.lockForConfiguration()
            let candidates = device.formats.filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width <= 3840 && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(options.fps) && $0.maxFrameRate >= Double(options.fps) }
            }
            if let format = candidates.min(by: { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription); let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return abs(Int(da.width) - options.width) < abs(Int(db.width) - options.width)
            }) { device.activeFormat = format; device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(options.fps)); device.activeVideoMaxFrameDuration = device.activeVideoMinFrameDuration }
            device.unlockForConfiguration()
        }
        if options.microphone && !options.needsScreen {
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            guard let device = devices.first(where: { $0.uniqueID == options.microphoneID }) ?? AVCaptureDevice.default(for: .audio) else { throw RecorderError.message("未找到麦克风。") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError.message("无法打开麦克风。") }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw RecorderError.message("无法添加麦克风输出。") }
            session.addOutput(output)
        }
        session.commitConfiguration()
        self.session = session
    }
    private func prepareStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == options.displayID }) ?? content.displays.first else { throw RecorderError.message("未找到显示器。") }
        let filter: SCContentFilter
        switch options.mode {
        case .windows:
            let selected = content.windows.filter { options.windowIDs.contains($0.windowID) }
            guard selected.count == options.windowIDs.count else { throw RecorderError.message("选中的窗口已关闭，请刷新并重新选择。") }
            if selected.count == 1 { filter = SCContentFilter(desktopIndependentWindow: selected[0]) }
            else { filter = SCContentFilter(display: display, including: selected) }
        case .applications:
            let selected = content.applications.filter { options.applicationIDs.contains($0.bundleIdentifier) }
            guard !selected.isEmpty else { throw RecorderError.message("选中的应用已退出。") }
            filter = SCContentFilter(display: display, including: selected, exceptingWindows: [])
        default:
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.width = options.wantsVideo && options.mode != .camera ? options.width : 64
        config.height = options.wantsVideo && options.mode != .camera ? options.height : 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = options.cursor
        config.showMouseClicks = options.clicks
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.backgroundColor = CGColor.black
        if options.mode == .region {
            let bounds = CGRect(origin: .zero, size: display.frame.size)
            guard bounds.contains(options.region) else { throw RecorderError.message("录制区域超出选中显示器，请重新选择。") }
            config.sourceRect = options.region
        }
        config.capturesAudio = options.systemAudio
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = options.microphone
        if !options.microphoneID.isEmpty { config.microphoneCaptureDeviceID = options.microphoneID }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        if options.wantsVideo && options.mode != .camera { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if options.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
    }
    private func releaseStream() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        if options.wantsVideo && options.mode != .camera { try? stream.removeStreamOutput(self, type: .screen) }
        if options.systemAudio { try? stream.removeStreamOutput(self, type: .audio) }
        if options.microphone { try? stream.removeStreamOutput(self, type: .microphone) }
        self.stream = nil
    }
    func setPaused(_ value: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if value && !self.paused { self.pauseHost = CMClockGetTime(CMClockGetHostTimeClock()) }
                if !value && self.paused, let began = self.pauseHost { self.removedTime = self.removedTime + (CMClockGetTime(CMClockGetHostTimeClock()) - began); self.pauseHost = nil }
                self.paused = value
                continuation.resume()
            }
        }
    }
    func finish() async throws -> [String: Int] {
        await releaseStream()
        if session != nil { await withCheckedContinuation { continuation in queue.async { self.session?.stopRunning(); continuation.resume() } } }
        session = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.accepting = false
                guard let writer = self.writer, self.started else { self.writer?.cancelWriting(); continuation.resume(throwing: self.failure ?? RecorderError.message("未收到有效的媒体数据，请检查权限和设备。")); return }
                var end = (self.pauseHost ?? CMClockGetTime(CMClockGetHostTimeClock())) - self.removedTime
                if let last = self.lastVideoTime, end <= last { end = last + CMTime(value: 1, timescale: CMTimeScale(self.options.fps)) }
                writer.endSession(atSourceTime: end)
                [self.videoInput, self.systemInput, self.micInput].compactMap { $0 }.forEach { $0.markAsFinished() }
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume(returning: self.counts) }
                    else { continuation.resume(throwing: writer.error ?? self.failure ?? RecorderError.message("媒体文件写入失败。")) }
                }
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.failure = error; self.onFailure?(error.localizedDescription) } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
            appendVideo(image, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), camera: false)
        case .audio: appendAudio(sampleBuffer, input: systemInput, key: "system")
        case .microphone: appendAudio(sampleBuffer, input: micInput, key: "microphone")
        @unknown default: break
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            cameraFrame = image
            if counts["camera", default: 0] % 20 == 0 {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(image) {
                    let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image), row = CVPixelBufferGetBytesPerRow(image)
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    var maximum = 0, sum = 0, n = 0
                    for y in stride(from: 0, to: h, by: max(1, h/32)) { for x in stride(from: 0, to: w, by: max(1, w/32)) { let p = y*row+x*4; let value = max(Int(bytes[p]), Int(bytes[p+1]), Int(bytes[p+2])); maximum = max(maximum, value); sum += value; n += 1 } }
                    counts["cameraMax"] = max(counts["cameraMax", default: 0], maximum)
                    counts["cameraMeanMilli"] = sum * 1000 / max(1, n)
                    if counts["camera", default: 0] > 60 { onCameraSignal?(maximum > 4) }
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
            if accepting && !paused { counts["camera", default: 0] += 1 }
            if options.mode == .camera { appendVideo(image, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), camera: true) }
        } else { appendAudio(sampleBuffer, input: micInput, key: "microphone") }
    }
    private func begin(at time: CMTime, video: Bool) -> Bool {
        guard accepting && !paused, let writer, writer.status == .writing else { return false }
        if !started {
            if options.wantsVideo && !video { return false }
            writer.startSession(atSourceTime: time); firstTime = time; started = true
        }
        return firstTime.map { time >= $0 } ?? false
    }
    private func appendVideo(_ buffer: CVPixelBuffer, at source: CMTime, camera: Bool) {
        let time = source - removedTime
        guard begin(at: time, video: true), let input = videoInput, let adaptor, input.isReadyForMoreMediaData else { return }
        if let last = lastVideoTime, (time - last).seconds < 0.9 / Double(options.fps) { return }
        guard let pool = adaptor.pixelBufferPool else { return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { counts["dropped", default: 0] += 1; return }
        let canvas = CGRect(x: 0, y: 0, width: options.width, height: options.height)
        let cameraImage = cameraFrame.map { CIImage(cvPixelBuffer: $0) }
        let composed = VideoCompositor.compose(frame: CIImage(cvPixelBuffer: buffer), cameraFrame: cameraImage, cameraOnly: camera, options: options)
        context.render(composed, to: output, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
        if Date().timeIntervalSince(lastPreview) > 0.3 {
            lastPreview = Date()
            let scale = min(1, 720 / canvas.width)
            let thumbnail = composed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let image = context.createCGImage(thumbnail, from: thumbnail.extent) { onPreview?(image) }
        }
        if adaptor.append(output, withPresentationTime: time) { counts["video", default: 0] += 1; lastVideoTime = time }
        else { failure = writer?.error; counts["dropped", default: 0] += 1 }
    }
    private func appendAudio(_ sample: CMSampleBuffer, input: AVAssetWriterInput?, key: String) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample) - removedTime
        guard begin(at: time, video: false), let input, input.isReadyForMoreMediaData else { return }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else { return }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in timings.indices { timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - removedTime; if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - removedTime } }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &adjusted) == noErr, let adjusted else { return }
        if input.append(adjusted) { counts[key, default: 0] += 1 } else { failure = writer?.error }
        meter(sample, key: key)
    }
    private func meter(_ sample: CMSampleBuffer, key: String) {
        guard let description = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description), asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.pointee.mBitsPerChannel == 32, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0; var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return }
        let n = length / MemoryLayout<Float>.size
        let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: n)
        var sum: Float = 0
        for i in 0..<n { sum += floats[i] * floats[i] }
        let level = min(1, sqrt(sum / Float(max(1, n))) * 4)
        if key == "system" { systemLevel = level } else { micLevel = level }
        if Date().timeIntervalSince(lastMeter) > 0.1 { lastMeter = Date(); onLevels?(systemLevel, micLevel) }
    }
}
