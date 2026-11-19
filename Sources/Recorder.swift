import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

enum RecordingProduct {
    case gif(frames: [CGImage], delay: Double)
    case video(URL)
}

final class RegionRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "local.capture.recorder")
    private let annotations = LockedBox<[Annotation]>([])
    private let pointSizeBox = LockedBox<CGSize>(.zero)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var startTime: CMTime?
    private var gifFrames: [CGImage] = []
    private var lastGIFTime: CMTime?
    private var outputURL: URL?
    private let kind: CaptureKind
    private var failed: Error?

    init(kind: CaptureKind) {
        self.kind = kind
        super.init()
    }

    func setAnnotations(_ items: [Annotation]) {
        annotations.set(items)
    }

    func start(appKitRect: CGRect, screen: NSScreen) async throws {
        pointSizeBox.set(appKitRect.size)
        let filter = try await ScreenGrabber.contentFilter(for: screen)
        let source = ScreenGrabber.sanitizedSource(appKitRect, on: screen)
        guard source.width >= 2, source.height >= 2 else { throw CaptureError.emptyRegion }
        let scale = screen.backingScaleFactor
        var pixelWidth = Int((source.width * scale).rounded(.down))
        var pixelHeight = Int((source.height * scale).rounded(.down))
        if pixelWidth % 2 != 0 { pixelWidth -= 1 }
        if pixelHeight % 2 != 0 { pixelHeight -= 1 }
        guard pixelWidth >= 2, pixelHeight >= 2 else { throw CaptureError.emptyRegion }

        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: source.minX, y: source.minY, width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = true
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.captureResolution = .best
        let fps: Int32 = kind == .gif ? 10 : 30
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        if kind == .video {
            let url = Exporter.tempDirectory().appendingPathComponent("Capture-\(UUID().uuidString).mp4")
            outputURL = url
            try prepareWriter(url: url, width: pixelWidth, height: pixelHeight)
        }
        try await stream.startCapture()
    }

    func stop() async throws -> RecordingProduct {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let error = self.failed {
                    continuation.resume(throwing: error)
                    return
                }
                switch self.kind {
                case .gif:
                    guard !self.gifFrames.isEmpty else {
                        continuation.resume(throwing: CaptureError.noFrames)
                        return
                    }
                    continuation.resume(returning: .gif(frames: self.gifFrames, delay: 0.1))
                case .video:
                    guard let writer = self.writer, let input = self.input, let url = self.outputURL else {
                        continuation.resume(throwing: CaptureError.noFrames)
                        return
                    }
                    input.markAsFinished()
                    writer.finishWriting {
                        if writer.status == .completed {
                            continuation.resume(returning: .video(url))
                        } else {
                            continuation.resume(throwing: writer.error ?? CaptureError.message("Video encoding failed."))
                        }
                    }
                case .image:
                    continuation.resume(throwing: CaptureError.message("Images are not recorded."))
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let status = frameStatus(sampleBuffer)
        if let status, status != .complete && status != .started { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil { startTime = time }
        let zeroed = CMTimeSubtract(time, startTime ?? time)
        let items = annotations.get()
        let pointSize = pointSizeBox.get()

        switch kind {
        case .gif:
            if let lastGIFTime, CMTimeGetSeconds(CMTimeSubtract(zeroed, lastGIFTime)) < 0.09 { return }
            lastGIFTime = zeroed
            guard gifFrames.count < 120, let frame = renderedFrame(pixelBuffer, annotations: items, pointSize: pointSize) else { return }
            gifFrames.append(downscaleGIF(frame, maxSide: 1600))
        case .video:
            appendVideo(pixelBuffer, at: zeroed, annotations: items, pointSize: pointSize)
        case .image:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.failed = error }
    }

    private func renderedFrame(_ pixelBuffer: CVPixelBuffer, annotations: [Annotation], pointSize: CGSize) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !annotations.isEmpty, pointSize.width > 1 {
            image = Compositor.apply(annotations, to: image, pointSize: pointSize)
        }
        return ciContext.createCGImage(image, from: image.extent)
    }

    private func prepareWriter(url: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime, annotations: [Annotation], pointSize: CGSize) {
        guard let writer, let input, let adaptor else { return }
        if !sessionStarted {
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !annotations.isEmpty, pointSize.width > 1 {
            image = Compositor.apply(annotations, to: image, pointSize: pointSize)
        }
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        let fitted = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).cropped(to: bounds)
        ciContext.render(fitted, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor.append(output, withPresentationTime: time)
    }
}

private func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) else { return nil }
    if let dicts = attachments as? [[SCStreamFrameInfo: Any]],
       let value = dicts.first?[SCStreamFrameInfo.status] as? NSNumber,
       let status = SCFrameStatus(rawValue: value.intValue) {
        return status
    }
    return nil
}

private func downscaleGIF(_ image: CGImage, maxSide: Int) -> CGImage {
    let longest = max(image.width, image.height)
    guard longest > maxSide else { return image }
    let scale = CGFloat(maxSide) / CGFloat(longest)
    let width = max(2, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(2, Int((CGFloat(image.height) * scale).rounded()))
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage() ?? image
}
