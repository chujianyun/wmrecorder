import SwiftUI
import AVFoundation
import ScreenCaptureKit
import AppKit

@MainActor
final class Permissions: ObservableObject {
    @Published var screen = false
    @Published var microphone = false
    @Published var camera = false
    @Published var message = "请依次完成授权，后续更新保持同一签名身份。"
    func refresh() {
        screen = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let state: [String: Any] = ["screen": screen, "microphone": microphone, "camera": camera, "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WMRecorder")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("permissions.json"), options: .atomic)
        }
    }
    func requestAll() async {
        message = "请在系统弹窗中允许麦克风与摄像头，然后开启屏幕录制。"
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        refresh()
        if !screen { settings("Privacy_ScreenCapture") } else { await verifyScreenCapture() }
        message = "开启权限后点击「检查授权」。如果系统要求退出并重新打开，请允许。"
    }
    func verifyScreenCapture() async {
        guard screen else { settings("Privacy_ScreenCapture"); return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw RecorderError.message("未找到显示器。") }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration(); config.width = 64; config.height = 64
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            message = "已成功读取屏幕。macOS 首次使用或周期性确认仍可能需要你点击允许。"
        } catch { message = "实际采集验证：\(error.localizedDescription)" }
        refresh()
    }
    func settings(_ pane: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) }
}

struct PermissionView: View {
    @StateObject private var permissions = Permissions()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Image(systemName: "record.circle.fill").font(.system(size: 42)).foregroundStyle(.red); VStack(alignment: .leading) { Text("WMRecorder · 悟鸣录屏").font(.title.bold()); Text("系统权限").foregroundStyle(.secondary) } }
            Text("完成录制需要的权限设置，所有素材保存在本机。").font(.headline)
            permission("屏幕与系统声音", allowed: permissions.screen, icon: "display", pane: "Privacy_ScreenCapture")
            permission("麦克风", allowed: permissions.microphone, icon: "mic", pane: "Privacy_Microphone")
            permission("摄像头", allowed: permissions.camera, icon: "video", pane: "Privacy_Camera")
            Text(permissions.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("开始授权") { Task { await permissions.requestAll() } }.buttonStyle(.borderedProminent).controlSize(.large); Button("检查实际采集") { Task { permissions.refresh(); await permissions.verifyScreenCapture() } }; Spacer(); if permissions.screen && permissions.microphone && permissions.camera { Label("授权已就绪", systemImage: "checkmark.seal.fill").foregroundStyle(.green) } }
            Divider()
            Text("后续更新继续使用已有授权，保留你的录制文件与设置。").font(.caption).foregroundStyle(.secondary)
        }.padding(32).frame(width: 570)
        .onAppear { permissions.refresh() }
        .onReceive(timer) { _ in permissions.refresh() }
    }
    func permission(_ title: String, allowed: Bool, icon: String, pane: String) -> some View {
        HStack { Image(systemName: icon).frame(width: 26); Text(title); Spacer(); Label(allowed ? "已允许" : "待授权", systemImage: allowed ? "checkmark.circle.fill" : "circle").foregroundStyle(allowed ? .green : .orange); Button("系统设置") { permissions.settings(pane) } }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}


@main struct WMRecorderApp: App {
    @StateObject private var model = RecorderModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("悟鸣录屏", id: "main") { MainView(model: model) }.defaultSize(width: 1120, height: 800)
        MenuBarExtra {
            Button("显示录制窗口") { model.hotkeys?.show() }
            Text(model.recording ? model.timeText : model.status)
            Divider()
            Button("开始录制") { model.start() }.disabled(model.isActive)
            Button(model.paused ? "恢复录制" : "暂停录制") { Task { await model.togglePause() } }.disabled(!model.recording || model.busy)
            Button("停止并保存") { Task { await model.stop() } }.disabled(!model.recording || model.busy)
            Divider()
            Button("媒体库") { model.page = "媒体库"; model.hotkeys?.show() }
            Button("打开录制目录") { model.openOutputDirectory() }
            Button("退出") { NSApp.terminate(nil) }
        } label: { Label(model.recording ? model.timeText : "", systemImage: model.recording ? "record.circle.fill" : "record.circle") }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = RecorderModel.shared
            if model.busy || model.testRunning { model.error = "正在保存、导出或测试，请完成后再退出。"; return .terminateCancel }
            if model.recording {
                Task {
                    await model.stop()
                    NSApp.reply(toApplicationShouldTerminate: !model.recording && !model.busy)
                }
                return .terminateLater
            }
            return .terminateNow
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
