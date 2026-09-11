import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox("文件保存") { VStack(alignment: .leading, spacing: 14) { HStack { Text(model.options.outputDirectory).lineLimit(2).textSelection(.enabled); Spacer(); Button("选择目录") { model.chooseOutputDirectory() } }; Toggle("录制完成后打开媒体库", isOn: $model.options.showLibraryAfter); HStack { Text("录制提醒"); Stepper("每 \(model.options.reminderMinutes) 分钟", value: $model.options.reminderMinutes, in: 0...120); Text("0 为关闭").foregroundStyle(.secondary) }; Text("录制页的参数会自动保存，下次启动继续使用。").font(.caption).foregroundStyle(.secondary) }.padding(12).accessibilityElement(children: .contain) }
                if let hotkeys = model.hotkeys { HotkeySettings(manager: hotkeys) }
                GroupBox("运行环境") { VStack(alignment: .leading, spacing: 10) { Label(MediaTools.shared.available ? "FFmpeg 已就绪" : "未安装 FFmpeg，请运行 brew install ffmpeg", systemImage: MediaTools.shared.available ? "checkmark.circle" : "exclamationmark.triangle"); Text("macOS 15 或更高版本 · 原生屏幕与音频采集\n固定签名身份与安装位置，更新不清理系统权限。").foregroundStyle(.secondary).font(.callout) }.frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            }.padding(24).accessibilityElement(children: .contain)
        }.disabled(model.isActive || model.testRunning)
    }
}
struct HotkeySettings: View {
    @ObservedObject var manager: HotkeyManager
    var body: some View {
        GroupBox("全局快捷键") { VStack(alignment: .leading, spacing: 12) {
            ForEach(manager.bindings) { binding in HStack { Text(binding.title); Spacer(); ShortcutRecorder(label: binding.label, onChange: { key, modifiers in manager.update(id: binding.id, key: key, modifiers: modifiers) }, onBegin: { manager.suspend() }, onCancel: { manager.register() }).frame(width: 160, height: 26) } }
            if !manager.conflict.isEmpty { Text(manager.conflict).font(.caption).foregroundStyle(.orange) }
            Text("点击组合键后输入新快捷键。无需辅助功能权限。").font(.caption).foregroundStyle(.secondary)
        }.padding(12).accessibilityElement(children: .contain) }
    }
}
struct TestPanel: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自动功能验收").font(.title3.bold())
            Text("将录制短暂的屏幕、系统音频、麦克风与摄像头测试片段，验证暂停、窗口／应用、画中画和导出。测试素材与报告保存在本机，不上传。").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button(model.testRunning ? "测试正在运行…" : "运行完整自检") { Task { await AutoTests.run(model: model, directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WMRecorder/Tests/\(Int(Date().timeIntervalSince1970))")) } }.buttonStyle(.borderedProminent).disabled(model.isActive || model.testRunning); if let report = model.lastTestReport { Button("查看测试记录") { NSWorkspace.shared.open(report) } } }
            if model.testRunning { ProgressView(); Text(model.status).font(.caption) }
        }.frame(maxWidth: 570).padding(20)
    }
}
