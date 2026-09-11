import AppKit
import SwiftUI
import Carbon

@MainActor
final class RegionSelector {
    private var window: NSWindow
    private var completion: (CGRect?) -> Void
    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false; window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.done = { [weak self] rect in self?.window.orderOut(nil); self?.completion(rect) }
        window.contentView = view
    }
    func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(window.contentView) }
}
private class SelectionWindow: NSWindow { override var canBecomeKey: Bool { true } }
private class SelectionView: NSView {
    var start: NSPoint?
    var selection: NSRect?
    var done: ((CGRect?) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
        if let selection {
            NSColor.clear.setFill(); selection.fill(using: .copy)
            NSColor.systemRed.setStroke(); let path = NSBezierPath(rect: selection); path.lineWidth = 3; path.stroke()
            let text = "\(Int(selection.width)) × \(Int(selection.height)) · 松开鼠标确认 · Esc 取消"
            (text as NSString).draw(at: NSPoint(x: selection.minX + 8, y: max(12, selection.minY - 30)), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white])
        } else { ("拖动选择录制区域 · Esc 取消" as NSString).draw(at: NSPoint(x: bounds.midX - 180, y: bounds.midY), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white]) }
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) { guard let start else { return }; let p = convert(event.locationInWindow, from: nil); selection = NSRect(x: min(p.x, start.x), y: min(p.y, start.y), width: abs(p.x-start.x), height: abs(p.y-start.y)).intersection(bounds); needsDisplay = true }
    override func mouseUp(with event: NSEvent) { guard let rect = selection, rect.width >= 16, rect.height >= 16 else { done?(nil); return }; done?(CGRect(x: rect.minX.rounded(), y: (bounds.height-rect.maxY).rounded(), width: rect.width.rounded(), height: rect.height.rounded())) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { done?(nil) } }
}

struct HotkeyBinding: Codable, Identifiable {
    var id: UInt32
    var title: String
    var key: UInt32
    var modifiers: UInt32
    static let defaults: [Self] = [
        .init(id: 1, title: "显示录制窗口", key: 13, modifiers: UInt32(controlKey | cmdKey)),
        .init(id: 2, title: "全屏模式", key: 18, modifiers: UInt32(controlKey | cmdKey)),
        .init(id: 3, title: "区域模式", key: 19, modifiers: UInt32(controlKey | cmdKey)),
        .init(id: 4, title: "摄像头模式", key: 20, modifiers: UInt32(controlKey | cmdKey)),
        .init(id: 5, title: "开始录制", key: 15, modifiers: UInt32(controlKey | cmdKey)),
        .init(id: 6, title: "暂停或恢复", key: 35, modifiers: UInt32(controlKey | cmdKey)),
        .init(id: 7, title: "停止保存", key: 17, modifiers: UInt32(controlKey | cmdKey)),
        .init(id: 8, title: "媒体库", key: 37, modifiers: UInt32(controlKey | cmdKey)),
        .init(id: 9, title: "打开输出目录", key: 3, modifiers: UInt32(controlKey | cmdKey))
    ]
    var label: String { (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + Self.keyNames[key, default: "\(key)"] }
    static let keyNames: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",49:"Space"]
}
@MainActor
final class HotkeyManager: ObservableObject {
    @Published var bindings: [HotkeyBinding]
    @Published var conflict = ""
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var suspended = false
    private weak var model: RecorderModel?
    init(model: RecorderModel) {
        self.model = model
        if let data = UserDefaults.standard.data(forKey: "hotkeys"), let saved = try? JSONDecoder().decode([HotkeyBinding].self, from: data) { bindings = saved } else { bindings = HotkeyBinding.defaults }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            let actionID = id.id
            Task { @MainActor in manager.invoke(actionID) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.suspended else { return event }
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if let binding = self.bindings.first(where: { $0.key == UInt32(event.keyCode) && $0.modifiers == modifiers }) { self.invoke(binding.id); return nil }
            return event
        }
        register()
    }
    func suspend() { suspended = true; refs.forEach { UnregisterEventHotKey($0) }; refs = [] }
    func register() {
        suspended = false
        refs.forEach { UnregisterEventHotKey($0) }; refs = []; conflict = ""
        for binding in bindings {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.key, binding.modifiers, EventHotKeyID(signature: 0x574D5243, id: binding.id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { refs.append(reference) } else { conflict += "\(binding.title)（\(binding.label)）被其他应用占用。\n" }
        }
        if let data = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(data, forKey: "hotkeys") }
    }
    func update(id: UInt32, key: UInt32, modifiers: UInt32) { if let i = bindings.firstIndex(where: { $0.id == id }) { bindings[i].key = key; bindings[i].modifiers = modifiers; register() } }
    func invoke(_ id: UInt32) {
        guard let model else { return }
        switch id {
        case 1: show()
        case 2,3,4: if !model.isActive { model.options.mode = id == 2 ? .display : id == 3 ? .region : .camera; model.page = "录制" }; show()
        case 5: model.start()
        case 6: Task { await model.togglePause() }
        case 7: Task { await model.stop() }
        case 8: model.page = "媒体库"; show()
        case 9: model.openOutputDirectory()
        default: break
        }
    }
    func show() { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.title == "悟鸣录屏" }?.makeKeyAndOrderFront(nil) }
}
struct ShortcutRecorder: NSViewRepresentable {
    var label: String
    var onChange: (UInt32, UInt32) -> Void
    var onBegin: () -> Void = {}
    var onCancel: () -> Void = {}
    func makeNSView(context: Context) -> ShortcutButton { let view = ShortcutButton(); view.onChange = onChange; view.onBegin = onBegin; view.onCancel = onCancel; view.normalTitle = label; view.title = label; view.bezelStyle = .rounded; view.target = view; view.action = #selector(ShortcutButton.arm); return view }
    func updateNSView(_ view: ShortcutButton, context: Context) { if !view.armed { view.title = label }; view.onChange = onChange; view.onBegin = onBegin; view.onCancel = onCancel; view.normalTitle = label }
}
class ShortcutButton: NSButton {
    var armed = false
    var normalTitle = ""
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onChange: ((UInt32, UInt32) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    @objc func arm() { onBegin?(); armed = true; title = "按下组合键…"; window?.makeFirstResponder(self) }
    override func resignFirstResponder() -> Bool { if armed { armed = false; title = normalTitle; onCancel?() }; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        guard armed else { super.keyDown(with: event); return }
        if event.keyCode == 53 { armed = false; title = normalTitle; onCancel?(); return }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else { title = "请带上 ⌘ / ⌃ / ⌥"; return }
        armed = false; onChange?(UInt32(event.keyCode), modifiers)
    }
}
