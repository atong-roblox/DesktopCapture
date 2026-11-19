import CoreGraphics
import CoreImage

enum Compositor {
    private static let contextLock = NSLock()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func composite(base: CGImage, annotations: [Annotation], pointSize: CGSize) -> CGImage {
        guard pointSize.width > 1, pointSize.height > 1, !annotations.isEmpty else { return base }
        let image = apply(annotations, to: CIImage(cgImage: base), pointSize: pointSize)
        contextLock.lock()
        let rendered = context.createCGImage(image, from: image.extent)
        contextLock.unlock()
        return rendered ?? base
    }

    static func apply(_ annotations: [Annotation], to source: CIImage, pointSize: CGSize) -> CIImage {
        guard pointSize.width > 1, pointSize.height > 1, !annotations.isEmpty else { return source }
        let origin = source.extent.origin
        var working = source.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let pixelSize = working.extent.size
        let scaleX = pixelSize.width / pointSize.width
        let scaleY = pixelSize.height / pointSize.height
        let lineScale = (scaleX + scaleY) / 2

        var pending: [Annotation] = []
        func flushVectors() {
            guard !pending.isEmpty else { return }
            if let overlay = vectorOverlay(pending, pixelSize: pixelSize, scaleX: scaleX, scaleY: scaleY, lineScale: lineScale) {
                working = overlay.composited(over: working)
            }
            pending.removeAll()
        }

        for annotation in annotations {
            if annotation.geometry.isMosaic {
                flushVectors()
                working = pixellate(working, annotation: annotation, scaleX: scaleX, scaleY: scaleY)
            } else {
                pending.append(annotation)
            }
        }
        flushVectors()
        return working.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    static func pixellated(_ image: CGImage, blockPixels: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = pixellateImage(input, blockPixels: blockPixels)
        contextLock.lock()
        let rendered = context.createCGImage(output, from: input.extent)
        contextLock.unlock()
        return rendered
    }
}

private func vectorOverlay(_ annotations: [Annotation], pixelSize: CGSize, scaleX: CGFloat, scaleY: CGFloat, lineScale: CGFloat) -> CIImage? {
    let width = Int(pixelSize.width.rounded())
    let height = Int(pixelSize.height.rounded())
    guard width > 0, height > 0 else { return nil }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    let map: (CGPoint) -> CGPoint = { point in
        CGPoint(x: point.x * scaleX, y: CGFloat(height) - point.y * scaleY)
    }
    for annotation in annotations {
        AnnotationRenderer.draw(annotation, in: ctx, map: map, lineScale: lineScale)
    }
    guard let image = ctx.makeImage() else { return nil }
    return CIImage(cgImage: image)
}

private func pixellate(_ image: CIImage, annotation: Annotation, scaleX: CGFloat, scaleY: CGFloat) -> CIImage {
    guard case let .mosaic(points, brush, strength) = annotation.geometry, !points.isEmpty else { return image }
    let height = image.extent.height
    let block = max(2, strength * (scaleX + scaleY) / 2)
    let brushPixels = max(1, brush * (scaleX + scaleY) / 2)
    let map: (CGPoint) -> CGPoint = { point in
        CGPoint(x: point.x * scaleX, y: height - point.y * scaleY)
    }
    guard let mask = maskImage(points: points, brush: brushPixels, pixelSize: image.extent.size, map: map) else {
        return image
    }
    let pixellated = pixellateImage(image, blockPixels: block)
    return pixellated.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: image,
        kCIInputMaskImageKey: mask
    ])
}

private func pixellateImage(_ image: CIImage, blockPixels: CGFloat) -> CIImage {
    let clamped = image.clampedToExtent()
    return clamped.applyingFilter("CIPixellate", parameters: [
        kCIInputScaleKey: blockPixels,
        kCIInputCenterKey: CIVector(x: image.extent.midX, y: image.extent.midY)
    ]).cropped(to: image.extent)
}

private func maskImage(points: [CGPoint], brush: CGFloat, pixelSize: CGSize, map: (CGPoint) -> CGPoint) -> CIImage? {
    let width = Int(pixelSize.width.rounded())
    let height = Int(pixelSize.height.rounded())
    guard width > 0, height > 0 else { return nil }
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let path = AnnotationRenderer.mosaicStrokePath(points: points, brush: brush, map: map)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    guard let image = ctx.makeImage() else { return nil }
    return CIImage(cgImage: image)
}
