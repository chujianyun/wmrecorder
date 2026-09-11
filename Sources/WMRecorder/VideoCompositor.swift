import CoreImage
import CoreGraphics

/// Pure composition, shared by hardware capture and pixel-level tests.
enum VideoCompositor {
    static func compose(frame: CIImage, cameraFrame: CIImage?, cameraOnly: Bool, options: RecordingOptions) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: options.width, height: options.height)
        let main = cameraOnly && options.mirror ? mirrored(frame) : frame
        var composed = fit(main, into: canvas).composited(over: CIImage(color: .black).cropped(to: canvas))
        if !cameraOnly && options.pictureInPicture, let cameraFrame {
            let camera = options.mirror ? mirrored(cameraFrame) : cameraFrame
            let w = canvas.width * options.pipScale, h = w * 0.75
            let margin = max(16, canvas.width * 0.018)
            let left = options.pipPosition == .bottomLeft || options.pipPosition == .topLeft
            let top = options.pipPosition == .topLeft || options.pipPosition == .topRight
            let rect = CGRect(x: left ? margin : canvas.width - w - margin, y: top ? canvas.height - h - margin : margin, width: w, height: h)
            let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect.insetBy(dx: -3, dy: -3))
            let backdrop = CIImage(color: .black).cropped(to: rect).composited(over: border)
            composed = fit(camera, into: rect).composited(over: backdrop).composited(over: composed)
        }
        return composed.cropped(to: canvas)
    }
    static func mirrored(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).transformed(by: CGAffineTransform(scaleX: -1, y: 1)).transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
    }
    static func fit(_ image: CIImage, into rect: CGRect) -> CIImage {
        let scale = min(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(translationX: rect.minX + (rect.width - scaled.extent.width) / 2, y: rect.minY + (rect.height - scaled.extent.height) / 2))
    }
}
