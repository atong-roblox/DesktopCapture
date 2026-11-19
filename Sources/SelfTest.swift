import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@discardableResult
func runSelfTest() -> Bool {
    var passed = true
    func fail(_ message: String) {
        captureLog("SELF-TEST FAIL: \(message)")
        passed = false
    }

    if let screen = NSScreen.screens.first {
        let top = CGRect(x: screen.frame.minX, y: screen.frame.maxY - 10, width: 10, height: 10)
        let source = DisplaySpace.sourceRect(forAppKitRect: top, on: screen)
        if abs(source.minX) > 0.01 || abs(source.minY) > 0.01 || abs(source.width - 10) > 0.01 {
            fail("top-left source rect \(source)")
        }
        let bottom = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 10, height: 10)
        let bottomSource = DisplaySpace.sourceRect(forAppKitRect: bottom, on: screen)
        if abs(bottomSource.minY - (screen.frame.height - 10)) > 0.01 {
            fail("bottom source rect \(bottomSource)")
        }
        let display = CGRect(x: 20, y: 30, width: 40, height: 50)
        let appKit = DisplaySpace.appKitRect(fromDisplay: display)
        let roundTrip = CGRect(
            x: appKit.minX,
            y: DisplaySpace.primaryHeight - appKit.maxY,
            width: appKit.width,
            height: appKit.height
        )
        if abs(roundTrip.minX - 20) > 0.01 || abs(roundTrip.minY - 30) > 0.01 {
            fail("display round trip \(roundTrip)")
        }
    } else {
        fail("no screen")
    }

    let base = solidImage(width: 200, height: 100, red: 0, green: 0, blue: 1)
    let annotation = Annotation(
        geometry: .rectangle(CGRect(x: 0, y: 0, width: 30, height: 20)),
        color: AnnotColor(r: 1, g: 1, b: 0, name: "Yellow"),
        lineWidth: 2,
        filled: true
    )
    let arrow = Annotation(
        geometry: .arrow(CGPoint(x: 60, y: 40), CGPoint(x: 140, y: 70)),
        color: AnnotColor(r: 1, g: 0.2, b: 0.2, name: "Red"),
        lineWidth: 4,
        filled: false
    )
    let result = Compositor.composite(base: base, annotations: [annotation, arrow], pointSize: CGSize(width: 200, height: 100))
    if result.width != 200 || result.height != 100 {
        fail("composite size \(result.width)x\(result.height)")
    }
    if let color = pixel(result, x: 8, yFromTop: 8), color.red < 0.15 {
        fail("top-left annotation missing, rgba \(color)")
    }
    if let color = pixel(result, x: 80, yFromTop: 8), color.red > 0.08 {
        fail("unexpected color outside annotation \(color)")
    }
    if let color = pixel(result, x: 8, yFromTop: 70), color.red > 0.08 {
        fail("annotation drawn at the bottom instead of the top \(color)")
    }

    let textSize = TextLayout.size(string: "Hello", font: .sans, fontSize: 20, width: 160)
    if textSize.height < 18 || textSize.width < 40 {
        fail("text layout \(textSize)")
    }
    let textBox = TextLayout.box(
        origin: CGPoint(x: 8, y: 20),
        width: 120,
        string: "Hi",
        font: .sans,
        fontSize: 28,
        limit: CGSize(width: 200, height: 100)
    )
    let textAnnotation = Annotation(
        geometry: .text(rect: textBox, string: "Hi", fontSize: 28, font: .sans),
        color: AnnotColor(r: 1, g: 1, b: 1, name: "White"),
        lineWidth: 1,
        filled: false
    )
    let withText = Compositor.composite(base: base, annotations: [textAnnotation], pointSize: CGSize(width: 200, height: 100))
    if withText.width != 200 || withText.height != 100 {
        fail("text composite size \(withText.width)x\(withText.height)")
    }
    let glyph = (18..<56).contains { y in
        (8..<70).contains { x in
            guard let color = pixel(withText, x: x, yFromTop: y) else { return false }
            return color.red > 0.85 && color.green > 0.85 && color.blue > 0.85
        }
    }
    if !glyph {
        fail("text glyph missing from the top of its box")
    }

    let url = URL(fileURLWithPath: "/tmp/capture-self-test.png")
    if let data = pngDataForTest(result) {
        try? data.write(to: url)
        captureLog("wrote \(url.path)")
    }
    let original = stripedImage(width: 40, height: 80) { UInt8(min(255, $0 * 3)) }
    let shifted = stripedImage(width: 40, height: 80) { y in
        y + 15 < 80 ? UInt8(min(255, (y + 15) * 3)) : 250
    }
    let stitcher = ScrollStitcher(image: original)
    if stitcher.integrate(original) != .unchanged || stitcher.image.height != 80 {
        fail("unchanged scroll frame was appended")
    }
    let detected = ScrollStitcher.shift(from: original, to: shifted)
    let outcome = stitcher.integrate(shifted)
    if outcome != .appended(15) || stitcher.image.height != 95 {
        fail("scroll stitch \(outcome) height \(stitcher.image.height) shift \(String(describing: detected))")
    }
    if let top = pixel(stitcher.image, x: 4, yFromTop: 0), top.red > 0.08 {
        fail("stitched image lost its top row \(top)")
    }
    if let added = pixel(stitcher.image, x: 4, yFromTop: 88), added.red < 0.9 {
        fail("stitched image missing the new rows \(added)")
    }

    if passed { captureLog("self-test passed") }
    return passed
}

private struct RGBA {
    var red, green, blue, alpha: CGFloat
}

private func pixel(_ image: CGImage, x: Int, yFromTop: Int) -> RGBA? {
    guard let color = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: yFromTop)?.usingColorSpace(.sRGB) else { return nil }
    return RGBA(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: color.alphaComponent)
}

private func stripedImage(width: Int, height: Int, shade: (Int) -> UInt8) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setShouldAntialias(false)
    context.interpolationQuality = .none
    for y in 0..<height {
        let gray = CGFloat(shade(y)) / 255
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 1 - y, width: width, height: 1))
    }
    return context.makeImage()!
}

private func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func pngDataForTest(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
