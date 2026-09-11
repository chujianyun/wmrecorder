import SwiftUI
import AVKit

struct MainView: View {
    @ObservedObject var model: RecorderModel
    let pages = [("录制", "record.circle"), ("媒体库", "rectangle.stack"), ("编辑导出", "slider.horizontal.3"), ("偏好设置", "gearshape"), ("授权与测试", "checkmark.shield")]
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Image(systemName: "record.circle.fill").font(.largeTitle).foregroundStyle(.red); VStack(alignment: .leading) { Text("悟鸣录屏").font(.title3.bold()); Text("WMRecorder").font(.caption).foregroundStyle(.secondary) } }.padding(.top, 20)
                ForEach(pages, id: \.0) { page, icon in
                    Button { model.page = page } label: { Label(page, systemImage: icon).font(.system(size: 14, weight: model.page == page ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(model.page == page ? Color.red.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
                }
                Spacer()
                Label(model.recording ? (model.paused ? "已暂停" : "录制中") : "本地录制 · 私密保存", systemImage: model.recording ? "record.circle.fill" : "lock.shield").font(.caption).foregroundStyle(model.recording ? .red : .secondary)
            }.padding(16).frame(minWidth: 180)
        } detail: {
            VStack(spacing: 0) {
                HStack { VStack(alignment: .leading, spacing: 5) { Text(model.page).font(.system(size: 26, weight: .bold)); Text(subtitle).font(.callout).foregroundStyle(.secondary) }; Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button { model.openOutputDirectory() } label: { Image(systemName: "folder") }.help("打开录制目录") }.padding(24)
                Divider()
                Group {
                    switch model.page {
                    case "媒体库": LibraryView(model: model)
                    case "编辑导出": EditorView(model: model)
                    case "偏好设置": PreferencesView(model: model)
                    case "授权与测试": ScrollView { VStack(spacing: 20) { PermissionView(); Divider(); TestPanel(model: model) }.padding() }
                    default: RecordingView(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack { Circle().fill(model.recording ? Color.red : Color.green).frame(width: 7, height: 7); Text(model.status).font(.caption).lineLimit(1); Spacer(); if model.recording { Text(model.timeText).monospacedDigit(); ProgressView(value: Double(max(model.systemLevel, model.micLevel))).frame(width: 55).help("声音电平"); Button(model.paused ? "恢复" : "暂停") { Task { await model.togglePause() } }; Button("停止保存") { Task { await model.stop() } }.tint(.red) } else if model.countdownValue > 0 { Button("取消倒计时") { model.cancelCountdown() } } else { Button("开始录制") { model.start() }.buttonStyle(.borderedProminent).tint(.red).disabled(model.busy || model.testRunning) } }.padding(12)
            }
        }.onChange(of: model.options.mode) { _, _ in model.previewImage = nil; Task { await model.stopCameraPreview() } }.navigationSplitViewStyle(.balanced).frame(minWidth: 960, minHeight: 700)
        .task { await model.initialize(); if !CGPreflightScreenCaptureAccess() { model.page = "授权与测试" }; await AutoTests.runIfRequested(model) }
        .alert("请检查", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    var subtitle: String { switch model.page { case "媒体库": return "查看、播放和整理你的录制"; case "编辑导出": return "截取精彩片段，调整画面与声音"; case "偏好设置": return "按你的习惯设置录制与快捷键"; case "授权与测试": return "检查系统权限，运行本机功能验收"; default: return "选好画面和声音，即刻开始" } }
}
struct RecordingView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button { model.options.mode = mode } label: { VStack(spacing: 8) { Image(systemName: mode.icon).font(.title2); Text(mode.rawValue).font(.callout) }.frame(maxWidth: .infinity).padding(.vertical, 17).background(model.options.mode == mode ? Color.red.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(model.options.mode == mode ? Color.red.opacity(0.5) : Color.clear)) }.buttonStyle(.plain)
                    }
                }.disabled(model.isActive || model.testRunning)
                sourceSection.accessibilityElement(children: .contain).disabled(model.isActive || model.testRunning)
                if let session = model.previewCameraSession { CameraLivePreview(session: session, mirror: model.options.mirror).frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 12)) }
                if let image = model.previewImage { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 230).frame(maxWidth: .infinity).background(.black, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel("实时录制预览") }
                if let warning = model.cameraWarning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                HStack(alignment: .top, spacing: 16) {
                    GroupBox("画面") { videoOptions.padding(10).accessibilityElement(children: .contain) }.frame(maxWidth: .infinity)
                    GroupBox("声音") { audioOptions.padding(10).accessibilityElement(children: .contain) }.frame(maxWidth: .infinity)
                }.disabled(model.isActive || model.testRunning)
                GroupBox("录制控制") {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) { Text(model.countdownValue > 0 ? "\(model.countdownValue)" : model.timeText).font(.system(size: 34, weight: .medium, design: .monospaced)); Text(model.recording ? (model.paused ? "已暂停 · 恢复后继续同一文件" : "正在录制 · 可从菜单栏控制") : "视频与声音保存在本机").foregroundStyle(.secondary).font(.caption) }
                        Spacer()
                        if model.countdownValue > 0 { Button("取消倒计时") { model.cancelCountdown() } }
                        else if model.recording { Button(model.paused ? "恢复" : "暂停") { Task { await model.togglePause() } }.controlSize(.large); Button("停止并保存") { Task { await model.stop() } }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large) }
                        else { Button { model.start() } label: { Label("开始录制", systemImage: "record.circle").padding(.horizontal, 12) }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(model.busy) }
                    }.padding(16)
                }
            }.padding(24).accessibilityElement(children: .contain)
        }
    }
    @ViewBuilder var sourceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label("录制来源", systemImage: "viewfinder").font(.headline); Spacer(); Button("刷新来源") { Task { await model.refreshSources(); model.refreshDevices() } } }
                if model.options.mode != .camera {
                    Picker("显示器", selection: $model.options.displayID) { ForEach(model.displays, id: \.displayID) { d in Text("显示器 \(d.displayID) · \(d.width) × \(d.height)").tag(d.displayID) } }
                }
                if model.options.mode == .region {
                    HStack { coordinate("X", $model.options.regionX); coordinate("Y", $model.options.regionY); coordinate("宽", $model.options.regionWidth); coordinate("高", $model.options.regionHeight); Button("拖动框选") { model.selectRegion() } }
                    Text("坐标以选中显示器左上角为原点，单位为屏幕点。").font(.caption).foregroundStyle(.secondary)
                }
                if model.options.mode == .windows {
                    ScrollView { VStack(alignment: .leading) { ForEach(model.windows, id: \.windowID) { window in Toggle("\(window.owningApplication?.applicationName ?? "应用") · \(window.title ?? "未命名窗口")", isOn: Binding(get: { model.options.windowIDs.contains(window.windowID) }, set: { value in if value { model.options.windowIDs.append(window.windowID) } else { model.options.windowIDs.removeAll { $0 == window.windowID } } })).lineLimit(1) } } }.frame(height: 120)
                    Text("选一个窗口可后台独立录制；多窗口按显示器上的位置组合。").font(.caption).foregroundStyle(.secondary)
                }
                if model.options.mode == .applications {
                    ScrollView { VStack(alignment: .leading) { ForEach(model.applications, id: \.bundleIdentifier) { app in Toggle(app.applicationName, isOn: Binding(get: { model.options.applicationIDs.contains(app.bundleIdentifier) }, set: { value in if value { model.options.applicationIDs.append(app.bundleIdentifier) } else { model.options.applicationIDs.removeAll { $0 == app.bundleIdentifier } } })) } } }.frame(height: 110)
                }
                if model.options.mode == .camera || model.options.pictureInPicture { HStack { cameraPicker; Button(model.previewCameraSession == nil ? "预览摄像头" : "关闭预览") { Task { await model.toggleCameraPreview() } } } }
                if model.options.mode == .audio { Text("单独录制系统声音、麦克风，或将两者混音保存为 M4A。").foregroundStyle(.secondary) }
            }.padding(12)
        }
    }
    var videoOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("分辨率"); Spacer(); Menu("\(model.options.width) × \(model.options.height)") { Button("720p") { model.options.width = 1280; model.options.height = 720 }; Button("1080p") { model.options.width = 1920; model.options.height = 1080 }; Button("4K") { model.options.width = 3840; model.options.height = 2160 } } }
            HStack { TextField("宽", value: $model.options.width, format: .number); Text("×"); TextField("高", value: $model.options.height, format: .number) }.textFieldStyle(.roundedBorder)
            Picker("帧率", selection: $model.options.fps) { ForEach([15,24,25,30,50,60], id: \.self) { Text("\($0) fps").tag($0) } }
            Picker("画质", selection: $model.options.quality) { ForEach(Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Toggle("显示鼠标", isOn: $model.options.cursor)
            Toggle("显示鼠标点击", isOn: $model.options.clicks)
            if model.options.mode != .camera && model.options.mode != .audio { Toggle("摄像头画中画", isOn: $model.options.pictureInPicture) }
            if model.options.pictureInPicture || model.options.mode == .camera { Toggle("镜像摄像头", isOn: $model.options.mirror) }
            if model.options.pictureInPicture { Picker("画中画位置", selection: $model.options.pipPosition) { ForEach(PiPPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) } }; HStack { Text("大小"); Slider(value: $model.options.pipScale, in: 0.1...0.5) } }
        }.disabled(model.options.mode == .audio)
    }
    var audioOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("系统声音", isOn: $model.options.systemAudio)
            HStack { Text("音量"); Slider(value: $model.options.systemVolume, in: 0...2); Text("\(Int(model.options.systemVolume*100))%").monospacedDigit().frame(width: 42) }
            Toggle("麦克风", isOn: $model.options.microphone)
            Picker("设备", selection: $model.options.microphoneID) { Text("系统默认").tag(""); ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }
            HStack { Text("音量"); Slider(value: $model.options.microphoneVolume, in: 0...2); Text("\(Int(model.options.microphoneVolume*100))%").monospacedDigit().frame(width: 42) }
            Picker("音轨", selection: $model.options.audioLayout) { ForEach(AudioLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Divider()
            Stepper("倒计时：\(model.options.countdown) 秒", value: $model.options.countdown, in: 0...10)
            HStack { Text("自动停止"); TextField("秒", value: $model.options.duration, format: .number).textFieldStyle(.roundedBorder); Text("秒") }
            Text("0 表示不限时长。静音仅影响最终文件。").font(.caption).foregroundStyle(.secondary)
        }
    }
    var cameraPicker: some View { Picker("摄像头", selection: $model.options.cameraID) { Text("系统默认").tag(""); ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } } }
    func coordinate(_ title: String, _ value: Binding<Double>) -> some View { HStack { Text(title); TextField(title, value: value, format: .number.precision(.fractionLength(0))).textFieldStyle(.roundedBorder).frame(minWidth: 45) } }
}
