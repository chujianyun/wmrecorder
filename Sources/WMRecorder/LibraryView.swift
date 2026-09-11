import SwiftUI
import AVKit

struct LibraryView: View {
    @ObservedObject var model: RecorderModel
    @State private var search = ""
    @State private var sort = "最新"
    @State private var renameItem: MediaItem?
    @State private var renameText = ""
    @State private var trashItem: MediaItem?
    var items: [MediaItem] {
        let items = model.library.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        switch sort { case "名称": return items.sorted { $0.name < $1.name }; case "时长": return items.sorted { $0.duration > $1.duration }; case "大小": return items.sorted { $0.size > $1.size }; case "类型": return items.sorted { $0.url.pathExtension < $1.url.pathExtension }; default: return items.sorted { $0.created > $1.created } }
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack { TextField("搜索录制", text: $search).textFieldStyle(.roundedBorder); Picker("排序", selection: $sort) { ForEach(["最新", "名称", "时长", "大小", "类型"], id: \.self) { Text($0) } }.frame(width: 150); Button("导入素材") { model.importMedia() }; Button { Task { await model.refreshLibrary() } } label: { Image(systemName: "arrow.clockwise") } }
            if items.isEmpty { ContentUnavailableView("还没有录制文件", systemImage: "film.stack", description: Text("录制完成后会出现在这里，也可以导入已有视频。")) }
            else {
                HSplitView {
                    List(items, selection: $model.selectedMedia) { item in
                        HStack(spacing: 12) { Image(systemName: item.isAudio ? "waveform" : "film").font(.title2).foregroundStyle(.red).frame(width: 28); VStack(alignment: .leading, spacing: 6) { Text(item.name).lineLimit(1); Text("\(RecorderModel.timeText(item.duration)) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.url.pathExtension.uppercased())").font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(.vertical, 5).tag(item.url)
                            .contextMenu { Button("播放") { model.selectedMedia = item.url }; Button("编辑／转换压缩") { model.selectedMedia = item.url; model.page = "编辑导出" }; Button("重命名") { renameText = item.url.deletingPathExtension().lastPathComponent; renameItem = item }; Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }; Divider(); Button("移出列表（保留文件）") { model.hide(item) }; Button("移到废纸篓", role: .destructive) { trashItem = item } }
                    }.frame(minWidth: 270)
                    VStack(alignment: .leading, spacing: 14) {
                        if let url = model.selectedMedia { MediaPlayerView(url: url).frame(minHeight: 210); Text(url.lastPathComponent).font(.headline).lineLimit(2); HStack { Button("编辑与导出") { model.page = "编辑导出" }.buttonStyle(.borderedProminent).tint(.red); Button("显示文件") { NSWorkspace.shared.activateFileViewerSelecting([url]) } } }
                        else { ContentUnavailableView("选择一个文件", systemImage: "play.rectangle") }
                        Spacer()
                    }.padding().frame(minWidth: 260)
                }
            }
        }.padding(24)
        .alert("重命名", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) { TextField("名称", text: $renameText); Button("取消", role: .cancel) { renameItem = nil }; Button("保存") { if let item = renameItem { do { try model.rename(item, to: renameText) } catch { model.error = error.localizedDescription } }; renameItem = nil } }
        .alert("将文件移到废纸篓？", isPresented: Binding(get: { trashItem != nil }, set: { if !$0 { trashItem = nil } })) { Button("取消", role: .cancel) {}; Button("移到废纸篓", role: .destructive) { if let item = trashItem { model.trash(item) }; trashItem = nil } } message: { Text("可以从 Finder 废纸篓中恢复。") }
    }
}
struct MediaPlayerView: NSViewRepresentable {
    var url: URL
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.controlsStyle = .inline; view.allowsVideoFrameAnalysis = false; view.player = AVPlayer(url: url); context.coordinator.url = url; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { if context.coordinator.url != url { view.player?.pause(); view.player = AVPlayer(url: url); context.coordinator.url = url } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) { view.player?.pause(); view.player = nil }
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var url: URL? }
}
struct EditorView: View {
    @ObservedObject var model: RecorderModel
    @State private var export = ExportOptions()
    @State private var info: MediaInfo?
    @State private var cropEnabled = false
    @State private var cropX = 0.0
    @State private var cropY = 0.0
    @State private var cropW = 1280.0
    @State private var cropH = 720.0
    @State private var previewURL: URL?
    @State private var previewBusy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(model.selectedMedia?.lastPathComponent ?? "尚未选择素材").font(.headline).lineLimit(1); Spacer(); Button("打开素材") { model.importMedia() } }
                if let url = model.selectedMedia {
                    MediaPlayerView(url: previewURL ?? url).frame(height: 260).background(.black, in: RoundedRectangle(cornerRadius: 12))
                    if let info { Text("时长 \(String(format: "%.2f", info.duration)) 秒 · \(info.video?.width ?? 0) × \(info.video?.height ?? 0) · \(info.audioCount) 条音轨").font(.caption).foregroundStyle(.secondary) }
                    HStack(alignment: .top, spacing: 16) {
                        GroupBox("画面与时间") { VStack(spacing: 12) {
                            field("开始（秒）", $export.start); field("结束（0 为结尾）", $export.end)
                            HStack { Text("宽 × 高"); TextField("宽", value: $export.width, format: .number); TextField("高", value: $export.height, format: .number) }.textFieldStyle(.roundedBorder)
                            Picker("帧率", selection: $export.fps) { ForEach([15,24,25,30,50,60], id: \.self) { Text("\($0) fps").tag($0) } }
                            Toggle("裁剪画面", isOn: $cropEnabled)
                            if cropEnabled { HStack { field("X", $cropX); field("Y", $cropY) }; HStack { field("宽", $cropW); field("高", $cropH) } }
                        }.padding(10).accessibilityElement(children: .contain) }.frame(maxWidth: .infinity)
                        GroupBox("导出设置") { VStack(spacing: 12) {
                            Picker("格式", selection: $export.format) { ForEach(["mp4", "mov", "mkv", "gif", "m4a", "mp3", "wav"], id: \.self) { Text($0.uppercased()).tag($0) } }
                            Picker("画质", selection: $export.quality) { ForEach(Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            Picker("音轨模式", selection: $export.layout) { ForEach(AudioLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            Picker("音轨选择", selection: $export.audioTrack) { Text("全部音轨").tag(-1); ForEach(0..<(info?.audioCount ?? 0), id: \.self) { Text("音轨 \($0+1)").tag($0) } }
                            HStack { Text("音量 \(Int(export.volume*100))%"); Slider(value: $export.volume, in: 0...2) }
                            Text("保留原始文件，导出到新文件。预览生成处理后的前 5 秒。").font(.caption).foregroundStyle(.secondary)
                        }.padding(10).accessibilityElement(children: .contain) }.frame(maxWidth: .infinity)
                    }.disabled(model.busy || previewBusy)
                    HStack { Button("预览效果") { Task { await preview(url) } }.disabled(model.busy || previewBusy || info == nil); if previewURL != nil { Button("查看原片") { previewURL = nil } }; Spacer(); Text(model.exportProgress).font(.caption); if model.busy || previewBusy { ProgressView().controlSize(.small); Button("取消") { MediaTools.shared.cancel() } }; Button("导出文件") { var config = export; config.crop = cropEnabled ? CGRect(x: cropX, y: cropY, width: cropW, height: cropH) : nil; Task { await model.exportMedia(input: url, options: config) } }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(model.busy || previewBusy || info == nil) }
                } else { ContentUnavailableView("打开一个视频或音频", systemImage: "slider.horizontal.3", description: Text("支持截取、裁剪、压缩、转换格式和音轨调整。")) }
            }.padding(24).accessibilityElement(children: .contain)
        }.disabled(model.recording || model.testRunning || model.countdownValue > 0).task(id: model.selectedMedia) { await loadInfo() }
    }
    func loadInfo() async {
        info = nil; previewURL = nil
        guard let url = model.selectedMedia else { return }
        do {
            let result = try await MediaTools.shared.probe(url); info = result; export = ExportOptions()
            export.width = result.video?.width ?? 1920; export.height = result.video?.height ?? 1080
            cropW = Double(export.width); cropH = Double(export.height)
            if result.video == nil { export.format = "m4a" }
        } catch { model.error = error.localizedDescription }
    }
    func preview(_ url: URL) async {
        guard let info else { return }
        previewBusy = true
        var config = export
        config.end = min(config.end > 0 ? config.end : info.duration, config.start + 5)
        config.crop = cropEnabled ? CGRect(x: cropX, y: cropY, width: cropW, height: cropH) : nil
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("WMRecorder-preview-\(UUID().uuidString).\(config.format)")
        do { _ = try await MediaTools.shared.export(input: url, output: output, options: config); previewURL = output } catch { model.error = error.localizedDescription }
        previewBusy = false
    }
    func field(_ label: String, _ binding: Binding<Double>) -> some View { HStack { Text(label); TextField(label, value: binding, format: .number).textFieldStyle(.roundedBorder) } }
}
