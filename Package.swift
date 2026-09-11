// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WMRecorder", platforms: [.macOS(.v15)], products: [.executable(name: "WMRecorder", targets: ["WMRecorder"])], targets: [.executableTarget(name: "WMRecorder", swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "WMRecorderTests", dependencies: ["WMRecorder"], swiftSettings: [.swiftLanguageMode(.v5)])])
