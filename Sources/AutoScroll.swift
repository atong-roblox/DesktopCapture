import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

enum AccessibilityPrompt {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func ask() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

enum ScrollWheel {
    /// Moves the document downward so new content enters from the bottom.
    /// The system inverts wheel deltas when natural scrolling is enabled.
    static func revealDown(points: CGFloat) async {
        let domain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let natural = domain?["com.apple.swipescrolldirection"] as? Bool ?? true
        let signed = Int32((natural ? points : -points).rounded())
        guard signed != 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let sign: Int32 = signed > 0 ? 1 : -1
        var remaining = abs(signed)
        while remaining > 0 {
            let chunk = min(remaining, 48)
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: sign * chunk,
                wheel2: 0,
                wheel3: 0
            ) else { return }
            event.location = cursorDisplayPoint()
            event.post(tap: .cghidEventTap)
            remaining -= chunk
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
        }
    }

    private static func cursorDisplayPoint() -> CGPoint {
        let appKit = NSEvent.mouseLocation
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
        return CGPoint(x: appKit.x, y: primary.frame.height - appKit.y)
    }
}

enum StitchOutcome: Equatable {
    case appended(Int)
    case unchanged
    case unaligned
}

final class ScrollStitcher {
    private(set) var image: CGImage
    private var previous: CGImage

    init(image: CGImage) {
        self.image = image
        self.previous = image
    }

    func integrate(_ next: CGImage) -> StitchOutcome {
        guard let next = Self.matchedViewport(next, to: previous) else { return .unaligned }
        guard let shift = Self.shift(from: previous, to: next) else { return .unaligned }
        if shift < 6 { return .unchanged }
        guard let combined = Self.append(bottomRows: shift, from: next, onto: image) else { return .unaligned }
        image = combined
        previous = next
        return .appended(shift)
    }

    private static func matchedViewport(_ image: CGImage, to previous: CGImage) -> CGImage? {
        guard image.width >= previous.width, image.height >= previous.height else { return nil }
        if image.width == previous.width, image.height == previous.height { return image }
        return image.cropping(to: CGRect(x: 0, y: 0, width: previous.width, height: previous.height))
    }

    /// How many pixels the content moved up between the two viewports.
    static func shift(from previous: CGImage, to next: CGImage) -> Int? {
        guard previous.width == next.width, previous.height == next.height,
              let older = grayscale(previous), let newer = grayscale(next) else { return nil }
        let width = previous.width
        let height = previous.height
        let maxShift = max(0, Int(Double(height) * 0.75))
        guard maxShift >= 6 else { return 0 }
        var bestShift = 0
        var bestScore = Int.max
        var shiftAt = [Int: Int]()
        for candidate in stride(from: 0, through: maxShift, by: 4) {
            let score = difference(older, newer, width: width, height: height, shift: candidate)
            shiftAt[candidate] = score
            if score < bestScore {
                bestScore = score
                bestShift = candidate
            }
        }
        let chosen = shiftAt
            .filter { $0.value <= bestScore + 4 }
            .map(\.key)
            .min() ?? bestShift
        var refined = chosen
        var refinedScore = shiftAt[chosen] ?? bestScore
        let lower = max(0, chosen - 3)
        let upper = min(maxShift, chosen + 3)
        if lower <= upper {
            for candidate in lower...upper {
                let score = difference(older, newer, width: width, height: height, shift: candidate)
                if score < refinedScore {
                    refinedScore = score
                    refined = candidate
                }
            }
        }
        if refinedScore > 22 { return nil }
        return refined
    }

    private static func difference(_ older: [UInt8], _ newer: [UInt8], width: Int, height: Int, shift: Int) -> Int {
        let x0 = max(1, width / 12)
        let x1 = max(x0 + 1, width - max(8, width / 12))
        var total = 0
        var count = 0
        var y = shift
        while y < height - 2 {
            let olderRow = y * width
            let newerRow = (y - shift) * width
            var x = x0
            while x < x1 {
                total += abs(Int(older[olderRow + x]) - Int(newer[newerRow + x]))
                count += 1
                x += 4
            }
            y += 2
        }
        guard count > 0 else { return .max }
        return total / count
    }

    private static func grayscale(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    static func append(bottomRows: Int, from next: CGImage, onto base: CGImage) -> CGImage? {
        let width = base.width
        guard bottomRows > 0, next.width == width, next.height > bottomRows else { return nil }
        let height = base.height + bottomRows
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(base, in: CGRect(x: 0, y: bottomRows, width: width, height: base.height))
        let strip = CGRect(x: 0, y: next.height - bottomRows, width: width, height: bottomRows)
        guard let cropped = next.cropping(to: strip) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: bottomRows))
        return context.makeImage()
    }
}

enum ImageFit {
    static func fitted(_ image: CGImage, maxPixelWidth: Int, maxPixelHeight: Int) -> CGImage {
        let scale = min(
            1,
            Double(maxPixelWidth) / Double(max(image.width, 1)),
            Double(maxPixelHeight) / Double(max(image.height, 1))
        )
        if scale > 0.99 { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

final class AutoScrollRunner {
    private weak var session: CaptureSession?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var stitcher: ScrollStitcher?
    private let panel = ScrollPreviewController()
    private var reportedStall = false
    private var reportedLimit = false

    init(session: CaptureSession) {
        self.session = session
    }

    func start() {
        guard let session, let selection = session.selection, let screen = screenContaining(selection) else { return }
        panel.onDone = { [weak self] in
            DispatchQueue.main.async { self?.session?.finishAutoScroll() }
        }
        panel.onCancel = { [weak self] in
            DispatchQueue.main.async { self?.session?.abortAutoScroll() }
        }
        panel.show(beside: selection, cursor: NSEvent.mouseLocation)
        let rect = selection
        task = Task { [weak self] in
            await self?.run(selection: rect, screen: screen)
        }
    }

    func stop() -> CGImage? {
        let image = stitcher?.image
        shutdown()
        return image
    }

    func cancel() {
        shutdown()
    }

    private func shutdown() {
        stopped = true
        task?.cancel()
        panel.close()
    }

    private func run(selection: CGRect, screen: NSScreen) async {
        do {
            try? await Task.sleep(nanoseconds: 80_000_000)
            let first = try await ScreenGrabber.captureStill(appKitRect: selection, screen: screen, showsCursor: false)
            let began: Bool = await MainActor.run {
                guard !stopped else { return false }
                let stitcher = ScrollStitcher(image: first)
                self.stitcher = stitcher
                panel.update(image: stitcher.image)
                return true
            }
            guard began else { return }
            var stalls = 0
            while !Task.isCancelled {
                let paused: Bool = await MainActor.run { stopped || panel.containsCursor() }
                if await MainActor.run(body: { stopped }) { return }
                if paused {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    continue
                }
                let tooLong = await MainActor.run { stitcher?.image.height ?? 0 >= 32_000 }
                if tooLong {
                    await MainActor.run { noteLimit() }
                    break
                }
                let step = max(72, selection.height * 0.4)
                await ScrollWheel.revealDown(points: step)
                try? await Task.sleep(nanoseconds: 360_000_000)
                if await MainActor.run(body: { stopped }) || Task.isCancelled { return }
                let next: CGImage
                do {
                    next = try await ScreenGrabber.captureStill(appKitRect: selection, screen: screen, showsCursor: false)
                } catch {
                    stalls += 1
                    if stalls >= 4 { await MainActor.run { noteStall() } }
                    continue
                }
                let outcome: StitchOutcome? = await MainActor.run {
                    guard !stopped, let stitcher else { return nil }
                    let outcome = stitcher.integrate(next)
                    if case .appended(let rows) = outcome, rows >= 6 {
                        panel.update(image: stitcher.image)
                        session?.banner = nil
                        reportedStall = false
                    }
                    return outcome
                }
                switch outcome {
                case .appended(let rows) where rows >= 6:
                    stalls = 0
                case .unchanged, .appended, .unaligned, .none:
                    stalls += 1
                }
                if stalls >= 4 { await MainActor.run { noteStall() } }
                if stalls >= 8 {
                    try? await Task.sleep(nanoseconds: 420_000_000)
                }
            }
        } catch {
            await MainActor.run {
                guard !stopped else { return }
                session?.banner = error.localizedDescription
                session?.abortAutoScroll()
            }
        }
    }

    private func noteStall() {
        guard !reportedStall else { return }
        reportedStall = true
        session?.banner = "No further movement. Done keeps this capture."
    }

    private func noteLimit() {
        guard !reportedLimit else { return }
        reportedLimit = true
        session?.banner = "Reached the length limit. Done keeps this capture."
    }
}

final class ScrollPreviewModel: ObservableObject {
    @Published var image: CGImage?
    @Published var fullHeight = 0
    @Published var token = 0
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ScrollPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ScrollPreviewController {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private let model = ScrollPreviewModel()
    private var window: ScrollPanel?

    func show(beside selection: CGRect, cursor: CGPoint) {
        let screen = screenContaining(selection) ?? NSScreen.main ?? NSScreen.screens[0]
        let height = min(max(selection.height, 320), screen.visibleFrame.height * 0.72)
        let size = NSSize(width: 272, height: height)
        var x = cursor.x > selection.midX ? selection.minX - 12 - size.width : selection.maxX + 12
        if x < screen.frame.minX + 8 { x = selection.maxX + 12 }
        if x + size.width > screen.frame.maxX - 8 { x = selection.minX - 12 - size.width }
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        var y = selection.midY - size.height / 2
        y = min(max(y, screen.frame.minY + 8), screen.frame.maxY - size.height - 8)
        let panel = ScrollPanel(
            contentRect: NSRect(origin: CGPoint(x: x, y: y), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.contentView = FirstMouseHostingView(rootView: ScrollPreviewCard(
            model: model,
            onDone: { [weak self] in self?.onDone?() },
            onCancel: { [weak self] in self?.onCancel?() }
        ))
        window = panel
        panel.orderFrontRegardless()
    }

    func update(image: CGImage) {
        guard window != nil else { return }
        model.fullHeight = image.height
        model.image = ImageFit.fitted(image, maxPixelWidth: 540, maxPixelHeight: 6000)
        model.token += 1
    }

    func containsCursor() -> Bool {
        guard let window else { return false }
        return window.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

struct ScrollPreviewCard: View {
    @ObservedObject var model: ScrollPreviewModel
    var onDone: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "scroll")
                    .font(.system(size: 12, weight: .semibold))
                Text("Auto Scroll")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            .foregroundStyle(Color(white: 0.12))
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                if let image = model.image {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            preview(image)
                                .id(model.token)
                        }
                        .onChange(of: model.token) { _, token in
                            proxy.scrollTo(token, anchor: .bottom)
                        }
                    }
                } else {
                    Text("Capturing…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(white: 0.35))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
            }
            HStack {
                Text(model.fullHeight > 0 ? "\(model.fullHeight) px" : " ")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: 0.28))
                Spacer()
            }
            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Finish and review")
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
        }
        .environment(\.colorScheme, .light)
    }

    private func preview(_ image: CGImage) -> some View {
        let width: CGFloat = 240
        let height = max(1, width * CGFloat(image.height) / CGFloat(max(image.width, 1)))
        return Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            .resizable()
            .interpolation(.medium)
            .frame(width: width, height: height)
    }
}
