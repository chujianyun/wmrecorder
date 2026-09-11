import Foundation

final class MediaTools: @unchecked Sendable {
    static let shared = MediaTools()
    private let lock = NSLock()
    private var active: Process?
    private var exportActive = false
    private var cancellationRequested = false
    static func executable(_ name: String) -> URL? {
        let candidates = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]
        return candidates.map { URL(fileURLWithPath: $0 + name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    var available: Bool { Self.executable("ffmpeg") != nil && Self.executable("ffprobe") != nil }
    func cancel() { lock.lock(); if exportActive { cancellationRequested = true }; let task = active; lock.unlock(); if task?.isRunning == true { task?.terminate() } }
    private func beginExport() throws {
        lock.lock(); defer { lock.unlock() }
        guard !exportActive else { throw RecorderError.message("已有导出任务正在运行，请等待完成或取消后重试。") }
        exportActive = true; cancellationRequested = false
    }
    private func endExport() { lock.lock(); exportActive = false; cancellationRequested = false; active = nil; lock.unlock() }
    private func cancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancellationRequested }

    func run(_ name: String, _ arguments: [String], cancellable: Bool = false) async throws -> Data {
        guard let executable = Self.executable(name) else { throw RecorderError.message("未找到 \(name)。请安装 FFmpeg 后再录制或导出。") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("wmrecorder-process-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                do {
                    let log = try FileHandle(forWritingTo: logURL)
                    defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardOutput = stdout
                    process.standardError = log
                    if cancellable { self.lock.lock(); self.active = process; self.lock.unlock() }
                    defer { if cancellable { self.lock.lock(); self.active = nil; self.lock.unlock() } }
                    if cancellable && self.cancelled() { throw CancellationError() }
                    try process.run()
                    if cancellable && self.cancelled() && process.isRunning { process.terminate() }
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if cancellable && self.cancelled() { throw CancellationError() }
                    guard process.terminationStatus == 0 else {
                        let error = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                        throw RecorderError.message("\(name) 执行失败（\(process.terminationStatus)）：\(error.suffix(1600))")
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func probe(_ url: URL) async throws -> MediaInfo {
        let data = try await run("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path])
        return try JSONDecoder().decode(MediaInfo.self, from: data)
    }
    static func exportArguments(input: URL, output: URL, options o: ExportOptions, info: MediaInfo, trackVolumes: [Double]? = nil) throws -> [String] {
        try o.validate(duration: info.duration)
        guard input.standardizedFileURL != output.standardizedFileURL else { throw RecorderError.message("导出文件不能覆盖原文件。") }
        guard ["mp4", "mov", "mkv", "gif", "m4a", "mp3", "wav"].contains(o.format) else { throw RecorderError.message("不支持此格式。") }
        let audioOnly = ["m4a", "mp3", "wav"].contains(o.format)
        if audioOnly && o.layout == .mute { throw RecorderError.message("音频文件不能以静音模式导出。") }
        if audioOnly && info.audioCount == 0 { throw RecorderError.message("素材没有音轨，无法导出音频。") }
        if let crop = o.crop, let v = info.video {
            guard crop.maxX <= Double(v.width ?? 0), crop.maxY <= Double(v.height ?? 0) else { throw RecorderError.message("裁剪区域超出原视频边界。") }
        }
        var args = ["-hide_banner", "-v", "error", "-nostdin", "-n", "-ss", String(o.start), "-i", input.path]
        if o.end > 0 { args += ["-t", String(o.end - o.start)] }
        var filters: [String] = []
        if info.video != nil && !audioOnly {
            var vf: [String] = []
            if let crop = o.crop { vf.append("crop=\(Int(crop.width)/2*2):\(Int(crop.height)/2*2):\(Int(crop.minX)):\(Int(crop.minY))") }
            vf += ["scale=\(o.width):\(o.height):force_original_aspect_ratio=decrease", "pad=\(o.width):\(o.height):(ow-iw)/2:(oh-ih)/2:color=black", "setsar=1", "fps=\(o.fps)"]
            if o.format == "gif" {
                filters.append("[0:v:0]\(vf.joined(separator: ",")),split[p0][p1];[p0]palettegen[pal];[p1][pal]paletteuse[vout]")
            } else { filters.append("[0:v:0]\(vf.joined(separator: ","))[vout]") }
            args += ["-map", "[vout]"]
            if o.format != "gif" { args += ["-c:v", "libx264", "-preset", "fast", "-crf", String(o.quality.crf), "-pix_fmt", "yuv420p"] }
        } else { args += ["-vn"] }
        let audioEnabled = info.audioCount > 0 && o.layout != .mute && o.format != "gif"
        if audioEnabled {
            let indices: [Int]
            if o.audioTrack >= 0 {
                guard o.audioTrack < info.audioCount else { throw RecorderError.message("选中的音轨不存在。") }
                indices = [o.audioTrack]
            } else { indices = Array(0..<info.audioCount) }
            for i in indices {
                let gain = (trackVolumes != nil && i < trackVolumes!.count ? trackVolumes![i] : 1) * o.volume
                filters.append("[0:a:\(i)]volume=\(gain),aresample=48000[a\(i)]")
            }
            if o.layout == .separate && !audioOnly {
                for i in indices { args += ["-map", "[a\(i)]"] }
            } else if indices.count > 1 {
                filters.append(indices.map { "[a\($0)]" }.joined() + "amix=inputs=\(indices.count):duration=longest:normalize=0,alimiter=limit=0.95:level=false[amix]")
                args += ["-map", "[amix]"]
            } else { args += ["-map", "[a\(indices[0])]"] }
            switch o.format { case "wav": args += ["-c:a", "pcm_s16le"]; case "mp3": args += ["-c:a", "libmp3lame", "-b:a", "192k"]; default: args += ["-c:a", "aac", "-b:a", "192k"] }
            args += ["-ac", o.layout == .mono ? "1" : "2"]
        } else { args += ["-an"] }
        if !filters.isEmpty { args += ["-filter_complex", filters.joined(separator: ";")] }
        if ["mp4", "mov", "m4a"].contains(o.format) { args += ["-movflags", "+faststart"] }
        args += ["-map_metadata", "-1", output.path]
        return args
    }
    func export(input: URL, output: URL, options: ExportOptions, trackVolumes: [Double]? = nil) async throws -> MediaInfo {
        try beginExport()
        defer { endExport() }
        let info = try await probe(input)
        if cancelled() { throw CancellationError() }
        let args = try Self.exportArguments(input: input, output: output, options: options, info: info, trackVolumes: trackVolumes)
        _ = try await run("ffmpeg", args, cancellable: true)
        let result = try await probe(output)
        guard result.duration > 0 else { throw RecorderError.message("导出的媒体没有有效时长，原始素材已保留。") }
        return result
    }
}
