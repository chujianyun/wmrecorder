import XCTest
import CoreImage
@testable import WMRecorder

final class CompositorTests: XCTestCase {
    let context = CIContext()
    func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) -> CIImage { CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: rect) }
    func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [UInt8] { var bytes = [UInt8](repeating: 0, count: 4); context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()); return bytes }
    func testCameraMirrorSwapsColoredHalves() {
        let frame = solid(1,0,0,CGRect(x: 0,y: 0,width: 32,height: 64)).composited(over: solid(0,0,1,CGRect(x: 32,y: 0,width: 32,height: 64)))
        var o = RecordingOptions(); o.width = 64; o.height = 64; o.mirror = false
        let original = VideoCompositor.compose(frame: frame, cameraFrame: nil, cameraOnly: true, options: o)
        XCTAssertGreaterThan(pixel(original, 10, 30)[0], 240)
        o.mirror = true
        let mirrored = VideoCompositor.compose(frame: frame, cameraFrame: nil, cameraOnly: true, options: o)
        XCTAssertGreaterThan(pixel(mirrored, 10, 30)[2], 240)
        XCTAssertGreaterThan(pixel(mirrored, 50, 30)[0], 240)
    }
    func testPipPreservesScreenAndRendersCamera() {
        var o = RecordingOptions(); o.width = 320; o.height = 180; o.pictureInPicture = true; o.pipScale = 0.25
        let screen = solid(0,1,0,CGRect(x: 0,y: 0,width: 320,height: 180))
        let camera = solid(1,0,0,CGRect(x: 0,y: 0,width: 160,height: 80))
        let result = VideoCompositor.compose(frame: screen, cameraFrame: camera, cameraOnly: false, options: o)
        XCTAssertGreaterThan(pixel(result, 10, 10)[1], 240)
        XCTAssertGreaterThan(pixel(result, 250, 40)[0], 240)
        let letterbox = pixel(result, 250, 18)
        XCTAssertLessThan(letterbox[0], 5); XCTAssertLessThan(letterbox[1], 5); XCTAssertLessThan(letterbox[2], 5)
        let border = pixel(result, 222, 40)
        XCTAssertGreaterThan(border[0], 240); XCTAssertGreaterThan(border[1], 240); XCTAssertGreaterThan(border[2], 240)
    }
    func testAllPipPositions() {
        var o = RecordingOptions(); o.width = 320; o.height = 180; o.pictureInPicture = true; o.pipScale = 0.25
        let screen = solid(0,1,0,CGRect(x: 0,y: 0,width: 320,height: 180)), camera = solid(1,0,0,CGRect(x: 0,y: 0,width: 80,height: 60))
        for (position, point) in [(PiPPosition.bottomLeft, (40,40)), (.bottomRight, (260,40)), (.topLeft,(40,140)), (.topRight,(260,140))] {
            o.pipPosition = position
            let result = VideoCompositor.compose(frame: screen, cameraFrame: camera, cameraOnly: false, options: o)
            XCTAssertGreaterThan(pixel(result, point.0, point.1)[0], 240, "\(position)")
        }
    }
    func testAspectRatioPreservedWithBlackPadding() {
        var o = RecordingOptions(); o.width = 320; o.height = 180
        let source = solid(1,0,0,CGRect(x: 0,y: 0,width: 100,height: 100))
        let result = VideoCompositor.compose(frame: source, cameraFrame: nil, cameraOnly: false, options: o)
        XCTAssertLessThan(pixel(result, 10, 90)[0], 5)
        XCTAssertGreaterThan(pixel(result, 160, 90)[0], 240)
    }
}
