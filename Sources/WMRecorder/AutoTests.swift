import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
enum AutoTests {
    static func runIfRequested(_ model: RecorderModel) async {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--self-test"), args.indices.contains(index + 1) { await run(model: model, directory: URL(fileURLWithPath: args[index + 1])) }
    }
    static func run(model: RecorderModel, directory: URL) async {
        guard !model.isActive && !model.testRunning else { return }
        model.testRunning = true
        model.page = "授权与测试"
        var rows: [[String: String]] = []
        let original = model.options
        let originalSelection = model.selectedMedia
        let previousPage = "录制"
        let began = Date()
        var testWindow: NSWindow?
        defer { model.options = original; model.testRunning = false; testWindow?.close(); model.page = previousPage; model.selectedMedia = originalSelection; model.previewImage = nil; model.seconds = 0 }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { model.error = error.localizedDescription; return }
        let report = directory.appendingPathComponent("test-results.json")
        func save() {
            let result: [String: Any] = ["started": ISO8601DateFormatter().string(from: began), "updated": ISO8601DateFormatter().string(from: Date()), "rows": rows, "finished": false]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        }
        func row(_ name: String, _ status: String, _ detail: String) { rows.append(["name": name, "status": status, "detail": detail]); save() }
        row("permissions", CGPreflightScreenCaptureAccess() && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? "PASS" : "BLOCKED", "screen=\(CGPreflightScreenCaptureAccess()), microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), camera=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        guard MediaTools.shared.available else { row("dependencies", "BLOCKED", "FFmpeg missing"); model.status = "自检被阻塞：FFmpeg 未安装"; model.lastTestReport = report; return }
        let testCard = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 640, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        testCard.title = "WMRecorder Test Card"
        testCard.isReleasedWhenClosed = false
        let card = NSTextField(labelWithString: "WMRecorder\n自动录制测试卡\nRED · GREEN · BLUE\n0123456789\nScreen / Audio / Camera")
        card.font = .monospacedSystemFont(ofSize: 30, weight: .bold); card.textColor = .white; card.alignment = .center
        card.frame = NSRect(x: 20, y: 40, width: 600, height: 300)
        testCard.contentView?.wantsLayer = true; testCard.contentView?.layer?.backgroundColor = NSColor.systemIndigo.cgColor; testCard.contentView?.addSubview(card)
        testCard.orderFront(nil); testWindow = testCard
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let selected = content?.windows.first { $0.windowID == CGWindowID(testCard.windowNumber) }
        let ownApp = content?.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var base = RecordingOptions()
        base.outputDirectory = directory.path; base.countdown = 0; base.width = 640; base.height = 360; base.fps = 30; base.systemAudio = false; base.microphone = false; base.showLibraryAfter = false
        base.displayID = content?.displays.first?.displayID ?? 0
        let toneURL = directory.appendingPathComponent("test-tone.wav")
        _ = try? await MediaTools.shared.run("ffmpeg", ["-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000:duration=10", toneURL.path])
        var outputs: [URL] = []
        func capture(_ name: String, _ config: RecordingOptions, duration: Double = 2.2, pause: Bool = false) async {
            model.status = "自检：\(name)"
            model.error = nil
            await model.begin(config)
            guard model.recording else { row(name, "FAIL", model.error ?? "Capture did not start"); model.error = nil; return }
            var playback: Process?
            if config.systemAudio {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); process.arguments = ["-v", "0.01", toneURL.path]
                try? process.run(); playback = process
            }
            defer { if playback?.isRunning == true { playback?.terminate() } }
            if pause {
                try? await Task.sleep(for: .seconds(1))
                await model.togglePause()
                try? await Task.sleep(for: .seconds(1.2))
                await model.togglePause()
                try? await Task.sleep(for: .seconds(1.2))
            } else { try? await Task.sleep(for: .seconds(duration)) }
            await model.stop()
            guard let url = model.lastOutput else { row(name, "FAIL", model.error ?? "No output"); model.error = nil; return }
            do {
                let info = try await MediaTools.shared.probe(url)
                let counts = model.lastCounts
                guard info.duration > 0.6, info.duration < (pause ? 3.2 : duration + 2) else { throw RecorderError.message("Unexpected duration \(info.duration)") }
                if config.wantsVideo { guard info.video?.width == config.width && info.video?.height == config.height && (counts["video"] ?? 0) > 0 else { throw RecorderError.message("Video dimensions/frame count mismatch") } }
                if config.microphone { guard (counts["microphone"] ?? 0) > 0 && info.audioCount > 0 else { throw RecorderError.message("Microphone did not supply samples") } }
                if config.systemAudio { guard (counts["system"] ?? 0) > 0 && info.audioCount > 0 else { throw RecorderError.message("System audio did not supply samples") } }
                if config.mode == .camera || config.pictureInPicture { guard (counts["camera"] ?? 0) > 0 else { throw RecorderError.message("Camera did not supply frames") }; guard (counts["cameraMax"] ?? 0) > 4 else { throw RecorderError.message("Camera input frames are black; raw max=\(counts["cameraMax"] ?? -1), mean=\(counts["cameraMeanMilli"] ?? -1)") } }
                if config.audioLayout == .separate && config.microphone && config.systemAudio { guard info.audioCount == 2 else { throw RecorderError.message("Separate tracks were not preserved") } }
                _ = try await MediaTools.shared.run("ffmpeg", ["-v", "error", "-i", url.path, "-f", "null", "-"])
                outputs.append(url)
                if name == "window-background-pause-resume" {
                    let color = try await MediaTools.shared.run("ffmpeg", ["-v", "error", "-ss", "1", "-i", url.path, "-frames:v", "1", "-vf", "scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"])
                    guard color.count >= 3, Int(color[2]) > Int(color[0]) + 20 else { throw RecorderError.message("Window occlusion test failed: blue test card not visible") }
                }
                if name == "system-audio-only" {
                    let samples = try await MediaTools.shared.run("ffmpeg", ["-v", "error", "-i", url.path, "-f", "f32le", "-ac", "1", "-ar", "48000", "-"])
                    let rms: Double = samples.withUnsafeBytes { bytes in let floats = bytes.bindMemory(to: Float.self); return sqrt(floats.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, floats.count))) }
                    guard rms > 0.00001 else { throw RecorderError.message("System loopback tone was silent: RMS=\(rms)") }
                    row("system-audio-nonzero-tone", "PASS", "Generated 997Hz tone produced nonzero recorded audio; RMS=\(rms)")
                }
                row(name, "PASS", "duration=\(String(format: "%.3f", info.duration)); size=\(info.video?.width ?? 0)x\(info.video?.height ?? 0); audioTracks=\(info.audioCount); samples=\(counts); file=\(url.lastPathComponent)")
            } catch { row(name, "FAIL", error.localizedDescription) }
            model.error = nil
        }
        if CGPreflightScreenCaptureAccess() {
            await capture("display-30fps", base)
            var region = base; region.mode = .region; region.regionWidth = 640; region.regionHeight = 360
            await capture("region", region)
            if let selected {
                var window = base; window.mode = .windows; window.windowIDs = [selected.windowID]
                let cover = NSWindow(contentRect: testCard.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                cover.isReleasedWhenClosed = false; cover.backgroundColor = .red; cover.orderFront(nil)
                await capture("window-background-pause-resume", window, pause: true)
                cover.close()
                let second = NSWindow(contentRect: NSRect(x: 780, y: 140, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
                second.title = "WMRecorder Second Test"; second.isReleasedWhenClosed = false; second.backgroundColor = .systemOrange; second.orderFront(nil)
                window.windowIDs.append(CGWindowID(second.windowNumber)); await capture("multiple-windows", window); second.close()
            } else { row("window-capture", "BLOCKED", "Test window unavailable") }
            if let ownApp { var app = base; app.mode = .applications; app.applicationIDs = [ownApp.bundleIdentifier]; await capture("application-filter", app) }
            var fps = base; fps.fps = 60; await capture("display-60fps", fps)
            fps.fps = 15; fps.width = 3840; fps.height = 2160; await capture("display-4k-15fps", fps, duration: 1.8)
            var audio = base; audio.mode = .audio; audio.systemAudio = true
            await capture("system-audio-only", audio)
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                audio.microphone = true; await capture("audio-mix", audio)
                var screen = base; screen.systemAudio = true; screen.microphone = true; screen.audioLayout = .separate; await capture("screen-dual-audio", screen)
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { var audio = base; audio.mode = .audio; audio.microphone = true; await capture("microphone-only", audio) }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            var camera = base; camera.mode = .camera; camera.microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            await capture("camera-mirrored", camera, duration: 8)
            camera.mirror = false; await capture("camera-unmirrored", camera, duration: 3)
            if CGPreflightScreenCaptureAccess() { var pip = base; pip.pictureInPicture = true; pip.microphone = camera.microphone; await capture("screen-camera-pip", pip, duration: 3) }
        }
        if let input = outputs.first {
            do {
                var e = ExportOptions(); e.width = 320; e.height = 180; e.fps = 15; e.start = 0.2; e.end = 1.2; e.crop = CGRect(x: 0, y: 0, width: 320, height: 180); e.quality = .compact
                let output = directory.appendingPathComponent("edited-crop-trim.mp4")
                let info = try await MediaTools.shared.export(input: input, output: output, options: e)
                guard abs(info.duration - 1) < 0.2 && info.video?.width == 320 && info.video?.height == 180 else { throw RecorderError.message("Edit output mismatch") }
                row("edit-crop-trim-scale-fps", "PASS", "duration=\(info.duration), 320x180, 15fps")
            } catch { row("edit-crop-trim-scale-fps", "FAIL", error.localizedDescription) }
        }
        if CGPreflightScreenCaptureAccess() {
            var timed = base; timed.duration = 1.5
            await model.begin(timed)
            if model.recording {
                for _ in 0..<100 { if !model.recording && !model.busy { break }; try? await Task.sleep(for: .milliseconds(100)) }
                if model.recording { await model.stop(); row("automatic-stop", "FAIL", "Timed capture failed to stop") }
                else if let output = model.lastOutput, let info = try? await MediaTools.shared.probe(output), (1.3...2.5).contains(info.duration) { row("automatic-stop", "PASS", "duration=\(info.duration)") }
                else { row("automatic-stop", "FAIL", model.error ?? "Missing timed output") }
            } else { row("automatic-stop", "FAIL", model.error ?? "Failed to start") }
            var invalid = base; invalid.mode = .windows; invalid.windowIDs = [UInt32.max]
            await model.begin(invalid)
            if !model.recording && model.error != nil { row("closed-window-rejected", "PASS", "Closed target produced a clear error") } else { row("closed-window-rejected", "FAIL", "Unexpected capture state"); if model.recording { await model.stop() } }
            model.error = nil
        }
        if let i = CommandLine.arguments.firstIndex(of: "--stress-seconds"), CommandLine.arguments.indices.contains(i+1), let seconds = Double(CommandLine.arguments[i+1]), (10...600).contains(seconds), CGPreflightScreenCaptureAccess() {
            var stress = base; stress.width = 1920; stress.height = 1080; stress.systemAudio = true; stress.microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            await capture("stress-1080p-30fps-dual-audio", stress, duration: seconds)
        }
        let passes = rows.filter { $0["status"] == "PASS" }.count
        let failures = rows.filter { $0["status"] == "FAIL" }.count
        let blocked = rows.filter { $0["status"] == "BLOCKED" }.count
        let result: [String: Any] = ["started": ISO8601DateFormatter().string(from: began), "finishedAt": ISO8601DateFormatter().string(from: Date()), "finished": true, "sourceFingerprint": Bundle.main.object(forInfoDictionaryKey: "WMSourceFingerprint") as? String ?? "unknown", "passed": passes, "failed": failures, "blocked": blocked, "rows": rows]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report, options: .atomic) }
        let markdown = "# 本机自动验收\n\n通过 \(passes)，失败 \(failures)，阻塞 \(blocked)。\n\n| 用例 | 结果 | 证据 |\n| --- | --- | --- |\n" + rows.map { "| \($0["name"] ?? "") | \($0["status"] ?? "") | \(($0["detail"] ?? "").replacingOccurrences(of: "\n", with: " ")) |" }.joined(separator: "\n")
        try? markdown.write(to: directory.appendingPathComponent("test-report.md"), atomically: true, encoding: .utf8)
        model.lastTestReport = directory.appendingPathComponent("test-report.md")
        model.status = "自检完成：\(passes) 通过，\(failures) 失败，\(blocked) 阻塞"
        model.error = nil
    }
}
