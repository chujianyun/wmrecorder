import XCTest
import AppKit
@testable import WMRecorder

final class TerminationTests: XCTestCase {
    @MainActor func testQuitDuringRecordingTransitionKeepsApplicationAlive() {
        let model = RecorderModel.shared
        let previous = (model.recording, model.busy, model.testRunning, model.error)
        defer { (model.recording, model.busy, model.testRunning, model.error) = previous }
        model.recording = true; model.busy = true; model.testRunning = false
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertTrue(model.recording)
        XCTAssertTrue(model.busy)
    }
    @MainActor func testQuitDuringActiveDeviceTestIsRejected() {
        let model = RecorderModel.shared
        let previous = (model.recording, model.busy, model.testRunning, model.error)
        defer { (model.recording, model.busy, model.testRunning, model.error) = previous }
        model.recording = true; model.busy = false; model.testRunning = true
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertTrue(model.recording)
    }
}

final class RecorderTests: XCTestCase {
    func testAudioOnlyCannotBeMuted() { var o = RecordingOptions(); o.mode = .audio; o.audioLayout = .mute; XCTAssertThrowsError(try o.validate()) }
    func testNonFiniteRegionRejected() { var o = RecordingOptions(); o.mode = .region; o.regionWidth = .infinity; XCTAssertThrowsError(try o.validate()) }
    func testNonFiniteDurationRejected() { var o = RecordingOptions(); o.duration = .nan; XCTAssertThrowsError(try o.validate()) }
    func testNonFiniteCropRejected() { var o = ExportOptions(); o.crop = CGRect(x: 0, y: 0, width: Double.infinity, height: 100); XCTAssertThrowsError(try o.validate(duration: 5)) }
    func testDefaultOptionsAreValid() throws { try RecordingOptions().validate() }
    func testRejectsOddResolution() { var o = RecordingOptions(); o.width = 1919; XCTAssertThrowsError(try o.validate()) }
    func testRejectsExcessiveResolution() { var o = RecordingOptions(); o.width = 10000; XCTAssertThrowsError(try o.validate()) }
    func testRejectsInvalidFrameRate() { var o = RecordingOptions(); o.fps = 120; XCTAssertThrowsError(try o.validate()) }
    func testAudioRequiresADevice() { var o = RecordingOptions(); o.mode = .audio; o.systemAudio = false; XCTAssertThrowsError(try o.validate()); o.microphone = true; XCTAssertNoThrow(try o.validate()) }
    func testWindowsRequireSelection() { var o = RecordingOptions(); o.mode = .windows; XCTAssertThrowsError(try o.validate()); o.windowIDs = [42]; XCTAssertNoThrow(try o.validate()) }
    func testApplicationsRequireSelection() { var o = RecordingOptions(); o.mode = .applications; XCTAssertThrowsError(try o.validate()); o.applicationIDs = ["test.app"]; XCTAssertNoThrow(try o.validate()) }
    func testRejectsInvalidRegion() { var o = RecordingOptions(); o.mode = .region; o.regionX = -1; XCTAssertThrowsError(try o.validate()); o.regionX = 0; o.regionWidth = 0; XCTAssertThrowsError(try o.validate()) }
    func testMicrophoneOnlyDoesNotRequireScreen() { var o = RecordingOptions(); o.mode = .audio; o.systemAudio = false; o.microphone = true; XCTAssertFalse(o.needsScreen); XCTAssertFalse(o.wantsVideo) }
    func testCameraOnlyDoesNotRequireScreen() { var o = RecordingOptions(); o.mode = .camera; o.systemAudio = false; XCTAssertFalse(o.needsScreen); XCTAssertTrue(o.wantsVideo) }
    func testInvalidVolumeRejected() { var o = RecordingOptions(); o.microphoneVolume = 3; XCTAssertThrowsError(try o.validate()) }
    func testOptionsRoundTrip() throws { var o = RecordingOptions(); o.pictureInPicture = true; o.pipPosition = .topLeft; o.windowIDs = [3, 7]; o.audioLayout = .separate; o.outputDirectory = "/tmp/example"; XCTAssertEqual(try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(o)), o) }
    func testTrimRangeRejected() { var o = ExportOptions(); o.start = 3; o.end = 2; XCTAssertThrowsError(try o.validate(duration: 10)); o.end = 20; XCTAssertThrowsError(try o.validate(duration: 10)); o.start = .nan; XCTAssertThrowsError(try o.validate(duration: 10)) }
    func testValidTrim() throws { var o = ExportOptions(); o.start = 2; o.end = 5; try o.validate(duration: 10) }
    private func media() -> MediaInfo { .init(streams: [.init(codec_type: "video", codec_name: "h264", width: 640, height: 360), .init(codec_type: "audio", codec_name: "aac")], format: .init(duration: "5", size: "1000")) }
    func testRejectsInputOverwrite() { let url = URL(fileURLWithPath: "/tmp/source.mp4"); XCTAssertThrowsError(try MediaTools.exportArguments(input: url, output: url, options: .init(), info: media())) }
    func testRejectsOutOfBoundsCrop() { var o = ExportOptions(); o.crop = CGRect(x: 600, y: 0, width: 100, height: 100); XCTAssertThrowsError(try MediaTools.exportArguments(input: URL(fileURLWithPath: "/tmp/in.mp4"), output: URL(fileURLWithPath: "/tmp/out.mp4"), options: o, info: media())) }
    func testRejectsMissingAudioTrack() { var o = ExportOptions(); o.audioTrack = 2; XCTAssertThrowsError(try MediaTools.exportArguments(input: URL(fileURLWithPath: "/tmp/in.mp4"), output: URL(fileURLWithPath: "/tmp/out.mp4"), options: o, info: media())) }
    func testFileNamesRemainSingleArguments() throws { let name = "/tmp/spaces ' ; $(touch NEVER) [x].mp4"; let args = try MediaTools.exportArguments(input: URL(fileURLWithPath: name), output: URL(fileURLWithPath: "/tmp/output.mp4"), options: .init(), info: media()); XCTAssertTrue(args.contains(name)); XCTAssertTrue(args.contains("-n")) }
}

final class MediaIntegrationTests: XCTestCase {
    var directory: URL!
    var fixture: URL!
    override func setUp() async throws {
        guard MediaTools.shared.available else { throw XCTSkip("FFmpeg not installed") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WMRecorder-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixture = directory.appendingPathComponent("fixture with spaces.mp4")
        _ = try await MediaTools.shared.run("ffmpeg", ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=3", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3", "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=3", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", fixture.path])
    }
    override func tearDown() async throws { if let directory { try? FileManager.default.removeItem(at: directory) } }
    func testTrimCropResizeFrameRateAndMix() async throws {
        var o = ExportOptions(); o.start = 0.5; o.end = 2; o.width = 320; o.height = 180; o.fps = 15; o.crop = CGRect(x: 40, y: 20, width: 480, height: 270)
        let result = try await MediaTools.shared.export(input: fixture, output: directory.appendingPathComponent("edited.mp4"), options: o)
        XCTAssertEqual(result.duration, 1.5, accuracy: 0.12); XCTAssertEqual(result.video?.width, 320); XCTAssertEqual(result.video?.height, 180); XCTAssertEqual(result.video?.r_frame_rate, "15/1"); XCTAssertEqual(result.audioCount, 1)
    }
    func testSeparateAudioTracks() async throws { var o = ExportOptions(); o.width = 640; o.height = 360; o.layout = .separate; let info = try await MediaTools.shared.export(input: fixture, output: directory.appendingPathComponent("separate.mov"), options: o); XCTAssertEqual(info.audioCount, 2) }
    func testMuteRemovesAudio() async throws { var o = ExportOptions(); o.width = 320; o.height = 180; o.layout = .mute; let info = try await MediaTools.shared.export(input: fixture, output: directory.appendingPathComponent("mute.mp4"), options: o); XCTAssertEqual(info.audioCount, 0) }
    func testMonoAudioOnly() async throws { var o = ExportOptions(); o.format = "m4a"; o.layout = .mono; let info = try await MediaTools.shared.export(input: fixture, output: directory.appendingPathComponent("mono.m4a"), options: o); XCTAssertNil(info.video); XCTAssertEqual(info.streams.first?.channels, 1) }
    func testSelectedAudioTrackAndVolume() async throws { var o = ExportOptions(); o.format = "wav"; o.audioTrack = 1; o.volume = 0.5; let info = try await MediaTools.shared.export(input: fixture, output: directory.appendingPathComponent("track.wav"), options: o); XCTAssertEqual(info.audioCount, 1); XCTAssertEqual(info.streams.first?.codec_name, "pcm_s16le") }
    func testGIFExport() async throws { var o = ExportOptions(); o.format = "gif"; o.width = 160; o.height = 90; o.fps = 15; o.end = 1; let info = try await MediaTools.shared.export(input: fixture, output: directory.appendingPathComponent("animated.gif"), options: o); XCTAssertEqual(info.video?.codec_name, "gif"); XCTAssertEqual(info.audioCount, 0) }
    func testOutputIsNeverOverwritten() async throws { let data = try Data(contentsOf: fixture); do { _ = try await MediaTools.shared.export(input: fixture, output: fixture, options: .init()); XCTFail("Must reject overwrite") } catch {}; XCTAssertEqual(try Data(contentsOf: fixture), data) }
    func testVolumeChangesDecodedSamples() async throws {
        var o = ExportOptions(); o.format = "wav"; o.audioTrack = 0
        let loud = directory.appendingPathComponent("full.wav"), quiet = directory.appendingPathComponent("half.wav")
        _ = try await MediaTools.shared.export(input: fixture, output: loud, options: o)
        o.volume = 0.5
        _ = try await MediaTools.shared.export(input: fixture, output: quiet, options: o)
        func rms(_ url: URL) async throws -> Double {
            let data = try await MediaTools.shared.run("ffmpeg", ["-v", "error", "-i", url.path, "-f", "f32le", "-ac", "1", "-"])
            return data.withUnsafeBytes { bytes in let values = bytes.bindMemory(to: Float.self); return sqrt(values.reduce(0.0) { $0 + Double($1 * $1) } / Double(values.count)) }
        }
        let fullRMS = try await rms(loud), halfRMS = try await rms(quiet)
        XCTAssertEqual(halfRMS / fullRMS, 0.5, accuracy: 0.02)
    }
    func testMP3AndMKVFormats() async throws {
        var o = ExportOptions(); o.width = 320; o.height = 180
        o.format = "mp3"
        let audio = try await MediaTools.shared.export(input: fixture, output: directory.appendingPathComponent("audio.mp3"), options: o)
        XCTAssertNil(audio.video); XCTAssertEqual(audio.streams.first?.codec_name, "mp3")
        o.format = "mkv"
        let video = try await MediaTools.shared.export(input: fixture, output: directory.appendingPathComponent("video.mkv"), options: o)
        XCTAssertEqual(video.video?.codec_name, "h264"); XCTAssertEqual(video.audioCount, 1)
    }
    func testCancellationPreservesSource() async throws {
        let before = try Data(contentsOf: fixture)
        var o = ExportOptions(); o.width = 7680; o.height = 4320; o.fps = 60
        let input = fixture!, output = directory.appendingPathComponent("cancelled.mp4")
        let task = Task { try await MediaTools.shared.export(input: input, output: output, options: o) }
        try await Task.sleep(for: .milliseconds(100))
        MediaTools.shared.cancel()
        do { _ = try await task.value; XCTFail("Export should have been cancelled") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture), before)
    }
    func testCorruptInputFails() async throws { let file = directory.appendingPathComponent("corrupt.mp4"); try Data("not media".utf8).write(to: file); do { _ = try await MediaTools.shared.probe(file); XCTFail("Must reject corrupt media") } catch {} }
}
