import SwiftUI
import AVKit
import ScreenCaptureKit

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()
    @Published var options: RecordingOptions { didSet { if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "recordingOptions") } } }
    @Published var page = "录制"
    @Published var previewImage: NSImage?
    @Published var cameraWarning: String?
    @Published var previewCameraSession: AVCaptureSession?
    private var cameraPreview: CameraPreviewController?
    private var initialized = false
    private var statusTimer: Timer?
    @Published var status = "准备就绪"
    @Published var recording = false
    @Published var paused = false
    @Published var busy = false
    @Published var seconds = 0.0
    @Published var countdownValue = 0
    @Published var error: String?
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var applications: [SCRunningApplication] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    @Published var library: [MediaItem] = []
    @Published var selectedMedia: URL?
    @Published var systemLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var exportProgress = ""
    @Published var testRunning = false
    @Published var lastTestReport: URL?
    @Published var lastOutput: URL?
    @Published var lastCounts: [String: Int] = [:]
    private var engine: CaptureEngine?
    private var rawURL: URL?
    private var currentOptions: RecordingOptions?
    private var timer: Timer?
    private var startDate: Date?
    private var pauseDate: Date?
    private var pausedDuration = 0.0
    private var countdownTask: Task<Void, Never>?
    private var regionSelector: RegionSelector?
    private var lastReminder = 0
    var hotkeys: HotkeyManager?
    var isActive: Bool { recording || busy || countdownValue > 0 }
    var timeText: String { Self.timeText(seconds) }
    static func timeText(_ value: Double) -> String { let n = max(0, Int(value)); return String(format: "%02d:%02d:%02d", n/3600, n/60%60, n%60) }
    init() {
        if let data = UserDefaults.standard.data(forKey: "recordingOptions"), let saved = try? JSONDecoder().decode(RecordingOptions.self, from: data) { options = saved } else { options = RecordingOptions() }
    }
    func initialize() async {
        guard !initialized else { return }
        initialized = true
        if let i = CommandLine.arguments.firstIndex(of: "--page"), CommandLine.arguments.indices.contains(i+1) { page = CommandLine.arguments[i+1] }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.writeRuntime() } }
        refreshDevices()
        if CGPreflightScreenCaptureAccess() { await refreshSources() }
        await refreshLibrary()
        hotkeys = HotkeyManager(model: self)
    }
    func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    func refreshSources() async {
        guard CGPreflightScreenCaptureAccess() else { status = "请先完成屏幕录制授权"; return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            displays = content.displays
            windows = content.windows.filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier && $0.frame.width > 50 && $0.frame.height > 50 && $0.windowLayer == 0 }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            applications = content.applications.filter { app in app.bundleIdentifier != Bundle.main.bundleIdentifier && windows.contains { $0.owningApplication?.processID == app.processID } }.sorted { $0.applicationName < $1.applicationName }
            if !displays.contains(where: { $0.displayID == options.displayID }), let first = displays.first { options.displayID = first.displayID }
        } catch { self.error = error.localizedDescription }
    }
    func selectRegion() {
        guard let display = displays.first(where: { $0.displayID == options.displayID }), let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID }) else { error = "请先刷新并选择显示器。"; return }
        regionSelector = RegionSelector(screen: screen) { [weak self] rect in
            guard let self else { return }
            if let rect { options.regionX = rect.minX; options.regionY = rect.minY; options.regionWidth = rect.width; options.regionHeight = rect.height }
            regionSelector = nil
        }
        regionSelector?.show()
    }
    func start() {
        guard !isActive && !testRunning else { return }
        do { try options.validate() } catch { self.error = error.localizedDescription; return }
        guard MediaTools.shared.available else { error = "需要先安装 FFmpeg：brew install ffmpeg"; return }
        let snapshot = options
        countdownTask = Task {
            for n in stride(from: snapshot.countdown, through: 1, by: -1) {
                if Task.isCancelled { return }
                countdownValue = n; status = "\(n) 秒后开始"
                try? await Task.sleep(for: .seconds(1))
            }
            countdownValue = 0
            if Task.isCancelled { return }
            await begin(snapshot)
        }
    }
    func cancelCountdown() { countdownTask?.cancel(); countdownValue = 0; status = "已取消" }
    func begin(_ config: RecordingOptions) async {
        guard !recording && !busy else { return }
        busy = true; previewImage = nil; cameraWarning = nil; status = "正在打开录制源…"; error = nil; lastOutput = nil; lastCounts = [:]
        do {
            await stopCameraPreview()
            try config.validate()
            let output = URL(fileURLWithPath: config.outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let sessions = output.appendingPathComponent(".sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let raw = sessions.appendingPathComponent("\(UUID().uuidString).mov")
            let engine = CaptureEngine()
            engine.onFailure = { [weak self] message in Task { @MainActor in self?.error = message; if self?.recording == true { await self?.stop() } } }
            engine.onLevels = { [weak self] system, microphone in Task { @MainActor in self?.systemLevel = system; self?.micLevel = microphone } }
            engine.onCameraSignal = { [weak self] visible in Task { @MainActor in self?.cameraWarning = visible ? nil : "摄像头画面接近全黑，请检查光线、镜头遮挡或选择其他设备。" } }
            engine.onPreview = { [weak self] image in Task { @MainActor in self?.previewImage = NSImage(cgImage: image, size: .zero) } }
            self.engine = engine; rawURL = raw; currentOptions = config
            try await engine.start(options: config, rawURL: raw)
            recording = true; paused = false; seconds = 0; pausedDuration = 0; startDate = Date(); pauseDate = nil; lastReminder = 0
            status = "正在录制 · \(config.mode.rawValue)"
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        } catch { self.error = error.localizedDescription; status = "录制未开始"; engine = nil }
        busy = false
    }
    private func tick() {
        guard recording && !paused, let startDate else { return }
        seconds = Date().timeIntervalSince(startDate) - pausedDuration
        if let config = currentOptions {
            if config.duration > 0 && seconds >= config.duration { Task { await stop() } }
            if config.reminderMinutes > 0 {
                let interval = config.reminderMinutes * 60
                let index = Int(seconds) / interval
                if index > lastReminder { lastReminder = index; NSSound.beep(); status = "已录制 \(timeText) · 提醒" }
            }
        }
    }
    func togglePause() async {
        guard recording && !busy, let engine else { return }
        busy = true
        let next = !paused
        await engine.setPaused(next)
        if next { pauseDate = Date() } else if let pauseDate { pausedDuration += Date().timeIntervalSince(pauseDate); self.pauseDate = nil }
        paused = next; busy = false; status = paused ? "录制已暂停" : "正在录制"
    }
    func stop() async {
        guard recording && !busy, let engine, let rawURL, let config = currentOptions else { return }
        busy = true; recording = false; paused = false; timer?.invalidate(); timer = nil; status = "正在保存与混音…"
        do {
            lastCounts = try await engine.finish()
            var export = ExportOptions()
            export.width = config.width; export.height = config.height; export.fps = config.fps; export.quality = config.quality; export.layout = config.audioLayout; export.format = config.mode == .audio ? "m4a" : "mp4"
            if config.duration > 0 { export.end = min(config.duration, try await MediaTools.shared.probe(rawURL).duration) }
            let timestamp = DateFormatter(); timestamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let destination = URL(fileURLWithPath: config.outputDirectory).appendingPathComponent("\(config.mode.rawValue)-\(timestamp.string(from: Date()))-\(UUID().uuidString.prefix(4)).\(export.format)")
            let volumes = (config.systemAudio ? [config.systemVolume] : []) + (config.microphone ? [config.microphoneVolume] : [])
            _ = try await MediaTools.shared.export(input: rawURL, output: destination, options: export, trackVolumes: volumes)
            lastOutput = destination
            status = "已保存：\(destination.lastPathComponent)"
            // A successful final output replaces only this generated intermediate. Failed captures remain recoverable.
            try? FileManager.default.removeItem(at: rawURL)
            await refreshLibrary()
            selectedMedia = destination
            if config.showLibraryAfter && !testRunning { page = "媒体库" }
        } catch { self.error = error.localizedDescription; status = "保存失败，原始素材保留在输出目录的 .sessions 中" }
        self.engine = nil; busy = false; systemLevel = 0; micLevel = 0
    }
    func toggleCameraPreview() async {
        if cameraPreview != nil { await stopCameraPreview(); return }
        guard !isActive else { return }
        busy = true
        do { let preview = CameraPreviewController(); try await preview.start(deviceID: options.cameraID); cameraPreview = preview; previewCameraSession = preview.session }
        catch { self.error = error.localizedDescription }
        busy = false
    }
    func stopCameraPreview() async { if let cameraPreview { await cameraPreview.stop() }; cameraPreview = nil; previewCameraSession = nil }
    func writeRuntime() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WMRecorder")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "recording": recording, "busy": busy, "testRunning": testRunning, "countdown": countdownValue, "page": page, "status": status]
        if let data = try? JSONSerialization.data(withJSONObject: runtime) { try? data.write(to: directory.appendingPathComponent("runtime.json"), options: .atomic) }
    }
    func chooseOutputDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { options.outputDirectory = url.path; Task { await refreshLibrary() } }
    }
    func openOutputDirectory() { let url = URL(fileURLWithPath: options.outputDirectory); try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) }
    func refreshLibrary() async {
        let directory = URL(fileURLWithPath: options.outputDirectory)
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenMedia") ?? [])
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles])) ?? []
        let imports = (UserDefaults.standard.stringArray(forKey: "importedMedia") ?? []).map { URL(fileURLWithPath: $0) }
        let unique = Set(urls + imports)
        var result: [MediaItem] = []
        for url in unique where ["mp4", "mov", "m4a", "mp3", "wav", "mkv", "gif", "avi", "webm"].contains(url.pathExtension.lowercased()) && !hidden.contains(url.path) && FileManager.default.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            result.append(MediaItem(url: url, duration: duration.isFinite ? duration : 0, size: Int64(values?.fileSize ?? 0), created: values?.creationDate ?? Date()))
        }
        library = result.sorted { $0.created > $1.created }
    }
    func importMedia() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.movie, .audio, .image]
        if panel.runModal() == .OK {
            var existing = UserDefaults.standard.stringArray(forKey: "importedMedia") ?? []
            existing += panel.urls.map(\.path); UserDefaults.standard.set(Array(Set(existing)), forKey: "importedMedia")
            selectedMedia = panel.urls.first; Task { await refreshLibrary() }
        }
    }
    func rename(_ item: MediaItem, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), clean != ".", clean != ".." else { throw RecorderError.message("请输入有效的文件名。") }
        var destination = item.url.deletingLastPathComponent().appendingPathComponent(clean)
        if destination.pathExtension != item.url.pathExtension { destination.appendPathExtension(item.url.pathExtension) }
        if destination == item.url { return }
        try FileManager.default.moveItem(at: item.url, to: destination)
        var imports = UserDefaults.standard.stringArray(forKey: "importedMedia") ?? []
        imports.removeAll { $0 == item.url.path }; imports.append(destination.path); UserDefaults.standard.set(imports, forKey: "importedMedia")
        selectedMedia = destination; Task { await refreshLibrary() }
    }
    func hide(_ item: MediaItem) { var hidden = UserDefaults.standard.stringArray(forKey: "hiddenMedia") ?? []; hidden.append(item.url.path); UserDefaults.standard.set(hidden, forKey: "hiddenMedia"); Task { await refreshLibrary() } }
    func trash(_ item: MediaItem) { do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil); Task { await refreshLibrary() } } catch { self.error = error.localizedDescription } }
    func exportMedia(input: URL, options: ExportOptions) async {
        let panel = NSSavePanel(); panel.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + "-导出." + options.format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else { error = "目标文件已存在，请选择一个新名称以保留原文件。"; return }
        busy = true; exportProgress = "正在导出…"
        do { _ = try await MediaTools.shared.export(input: input, output: url, options: options); exportProgress = "导出完成"; NSWorkspace.shared.activateFileViewerSelecting([url]); await refreshLibrary() }
        catch { self.error = error.localizedDescription; exportProgress = "导出失败或取消，原文件保持不变" }
        busy = false
    }
}
