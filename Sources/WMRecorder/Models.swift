import Foundation
import CoreGraphics

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case display = "全屏", region = "区域", windows = "窗口", applications = "应用", camera = "摄像头", audio = "仅音频"
    var id: String { rawValue }
    var icon: String { switch self { case .display: return "display"; case .region: return "viewfinder"; case .windows: return "macwindow.on.rectangle"; case .applications: return "app.dashed"; case .camera: return "video"; case .audio: return "waveform" } }
}
enum Quality: String, Codable, CaseIterable { case compact = "体积优先", balanced = "均衡", high = "高画质"
    var crf: Int { switch self { case .compact: return 30; case .balanced: return 23; case .high: return 18 } }
    var bitrate: Int { switch self { case .compact: return 3_000_000; case .balanced: return 8_000_000; case .high: return 20_000_000 } }
}
enum AudioLayout: String, Codable, CaseIterable { case mix = "混合音轨", separate = "独立音轨", mono = "单声道", mute = "静音" }
enum PiPPosition: String, Codable, CaseIterable { case bottomRight = "右下", bottomLeft = "左下", topRight = "右上", topLeft = "左上" }
struct RecordingOptions: Codable, Equatable {
    var mode: CaptureMode = .display
    var displayID: UInt32 = 0
    var windowIDs: [UInt32] = []
    var applicationIDs: [String] = []
    var width = 1920
    var height = 1080
    var fps = 30
    var quality: Quality = .balanced
    var systemAudio = true
    var microphone = false
    var microphoneID = ""
    var cameraID = ""
    var pictureInPicture = false
    var mirror = true
    var pipPosition: PiPPosition = .bottomRight
    var pipScale = 0.24
    var systemVolume = 1.0
    var microphoneVolume = 1.0
    var audioLayout: AudioLayout = .mix
    var cursor = true
    var clicks = false
    var countdown = 3
    var duration = 0.0
    var regionX = 0.0
    var regionY = 0.0
    var regionWidth = 1280.0
    var regionHeight = 720.0
    var showLibraryAfter = true
    var reminderMinutes = 0
    var outputDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("WMRecorder").path
    var region: CGRect { CGRect(x: regionX, y: regionY, width: regionWidth, height: regionHeight) }
    var wantsVideo: Bool { mode != .audio }
    var needsScreen: Bool { mode != .camera && mode != .audio || systemAudio }
    func validate() throws {
        guard (64...7680).contains(width), (64...4320).contains(height), width % 2 == 0, height % 2 == 0 else { throw RecorderError.message("分辨率必须是偶数，宽 64–7680，高 64–4320。") }
        guard (15...60).contains(fps) else { throw RecorderError.message("帧率范围为 15–60。") }
        guard duration >= 0, duration.isFinite, (0...10).contains(countdown) else { throw RecorderError.message("时长或倒计时无效。") }
        guard mode != .audio || audioLayout != .mute else { throw RecorderError.message("仅音频模式不能选择静音。") }
        guard mode != .audio || systemAudio || microphone else { throw RecorderError.message("录音至少需要开启系统声音或麦克风。") }
        guard [regionX, regionY, regionWidth, regionHeight].allSatisfy({ $0.isFinite }) else { throw RecorderError.message("区域坐标必须是有限数值。") }
        guard mode != .region || (regionWidth >= 16 && regionHeight >= 16 && regionX >= 0 && regionY >= 0) else { throw RecorderError.message("录制区域无效。") }
        guard mode != .windows || !windowIDs.isEmpty else { throw RecorderError.message("请先选择至少一个窗口。") }
        guard mode != .applications || !applicationIDs.isEmpty else { throw RecorderError.message("请先选择至少一个应用。") }
        guard (0...2).contains(systemVolume), (0...2).contains(microphoneVolume), (0.1...0.5).contains(pipScale) else { throw RecorderError.message("音量或画中画尺寸无效。") }
    }
}
enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
struct MediaItem: Identifiable, Equatable {
    var url: URL
    var duration: Double = 0
    var size: Int64 = 0
    var created = Date()
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isAudio: Bool { ["m4a", "mp3", "wav", "aac", "flac"].contains(url.pathExtension.lowercased()) }
}
struct ExportOptions {
    var start = 0.0
    var end = 0.0
    var width = 1920
    var height = 1080
    var fps = 30
    var quality: Quality = .balanced
    var volume = 1.0
    var layout: AudioLayout = .mix
    var crop: CGRect? = nil
    var format = "mp4"
    var audioTrack = -1
    func validate(duration: Double) throws {
        guard start >= 0, start.isFinite, start < duration, end == 0 || end > start && end <= duration + 0.1 else { throw RecorderError.message("截取时间超出视频长度。") }
        guard width >= 64, height >= 64, width <= 7680, height <= 4320, width % 2 == 0, height % 2 == 0, (15...60).contains(fps), (0...2).contains(volume) else { throw RecorderError.message("导出参数无效。") }
        if let crop { guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy({ $0.isFinite }), crop.minX >= 0, crop.minY >= 0, crop.width >= 16, crop.height >= 16 else { throw RecorderError.message("裁剪区域无效。") } }
    }
}
struct MediaInfo: Codable {
    struct Stream: Codable { var codec_type: String?; var codec_name: String?; var width: Int?; var height: Int?; var sample_rate: String?; var channels: Int?; var r_frame_rate: String? }
    struct Format: Codable { var duration: String?; var size: String? }
    var streams: [Stream]
    var format: Format
    var duration: Double { Double(format.duration ?? "0") ?? 0 }
    var video: Stream? { streams.first { $0.codec_type == "video" } }
    var audioCount: Int { streams.filter { $0.codec_type == "audio" }.count }
}
