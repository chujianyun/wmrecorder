import AppKit
import Foundation
import Darwin

let executable = "/Applications/WMRecorder.app/Contents/MacOS/WMRecorder"
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.wuming.wmrecorder").filter { $0.executableURL?.path == executable }
let runtimeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WMRecorder/runtime.json")
for app in apps {
    guard let data = try? Data(contentsOf: runtimeURL), let runtime = try? JSONSerialization.jsonObject(with: data) as? [String: Any], runtime["pid"] as? Int32 == app.processIdentifier else {
        fputs("Cannot verify app state. Quit WMRecorder manually before installation.\n", stderr); exit(1)
    }
    guard !(runtime["recording"] as? Bool ?? true), !(runtime["busy"] as? Bool ?? true), !(runtime["testRunning"] as? Bool ?? true), runtime["countdown"] as? Int == 0 else {
        fputs("Recording, export or tests are active; installation stopped without interrupting work.\n", stderr); exit(1)
    }
    print("Requesting normal exit for verified idle PID \(app.processIdentifier)")
    guard app.terminate() else { fputs("Normal termination request was rejected.\n", stderr); exit(1) }
    let pid = app.processIdentifier
    func exited() -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
    for _ in 0..<100 { if exited() { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    guard exited() else { fputs("App did not exit; old installation preserved.\n", stderr); exit(1) }
}
