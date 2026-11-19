import AppKit
import Combine
import ObjectiveC
import SwiftUI

private enum ChromeFirstMouse {
    static let install: Void = {
        guard let original = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))),
              let replacement = class_getInstanceMethod(NSView.self, #selector(NSView.capture_acceptsFirstMouse(for:))) else { return }
        method_exchangeImplementations(original, replacement)
    }()
}

extension NSView {
    @objc func capture_acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if window is ChromePanel { return true }
        return capture_acceptsFirstMouse(for: event)
    }
}

final class CapturePanel: NSWindow {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { allowsKey }

    /// The system window-open animation scales and bounces a new window. The dim should just be there.
    override var animationBehavior: NSWindow.AnimationBehavior {
        get { .none }
        set {}
    }
}

/// Controls stay clickable while the full-screen overlay lets events through.
final class ChromePanel: NSPanel {
    override var animationBehavior: NSWindow.AnimationBehavior {
        get { .none }
        set {}
    }
}

final class OverlayHost<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Clear padding around a control. Fully transparent pixels pass the click onward.
final class PassThroughRoot: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class OverlayController {
    let session: CaptureSession
    private(set) var window: CapturePanel?
    private(set) var canvas: OverlayCanvas!
    private var topHost: OverlayHost<TopBar>!
    private var annotationHost: OverlayHost<AnnotationBar>!
    private var actionHost: OverlayHost<ActionRail>!
    private var chromeWindows: [ChromeWindow] = []
    private var passingThrough = false
    private var yielding = false
    private var passGeneration = 0
    private var activationObserver: NSObjectProtocol?
    private var observe: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    private struct ChromeWindow {
        let panel: ChromePanel
        let host: NSView
        let root: PassThroughRoot
    }

    init(session: CaptureSession) {
        self.session = session
    }

    func show() {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let window = CapturePanel(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if !CommandLine.arguments.contains("--preview") {
            window.sharingType = .none
        }
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.animationBehavior = .none

        let canvas = OverlayCanvas(session: session)
        window.contentView = canvas
        self.window = window
        self.canvas = canvas

        topHost = OverlayHost(rootView: TopBar(session: session))
        annotationHost = OverlayHost(rootView: AnnotationBar(session: session))
        actionHost = OverlayHost(rootView: ActionRail(session: session))
        for host in [topHost!, annotationHost!, actionHost!] as [NSView] {
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            host.layer?.masksToBounds = false
            canvas.addSubview(host)
        }
        topHost.sizingOptions = .intrinsicContentSize
        annotationHost.sizingOptions = .intrinsicContentSize
        actionHost.sizingOptions = .intrinsicContentSize
        canvas.prepareTextEditor()

        window.alphaValue = 0
        window.setFrame(union, display: false, animate: false)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(canvas)
        window.displayIfNeeded()
        NSAnimationContext.endGrouping()
        NSApp.activate()
        // Reveal on the next turn so the open animation cannot scale the dim into view.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            window.alphaValue = 1
            NSAnimationContext.endGrouping()
        }
        layout()
        DispatchQueue.main.async { [weak self] in self?.layout() }

        observe = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.layout()
                self?.canvas?.needsDisplay = true
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resizeToScreens()
        }
    }

    func close() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        observe = nil
        passGeneration += 1
        passingThrough = false
        stopWatchingActivation()
        let panels = chromeWindows
        chromeWindows = []
        for item in panels {
            item.panel.orderOut(nil)
        }
        DispatchQueue.main.async {
            for item in panels {
                item.host.removeFromSuperview()
                item.panel.close()
            }
        }
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    /// The overlay stops taking mouse and keyboard so the recorded window can be used.
    /// Stop and Cancel move to small panels that still receive clicks.
    func beginRecordingInteraction() {
        guard window != nil, !passingThrough else { return }
        passGeneration += 1
        let generation = passGeneration
        passingThrough = true
        window?.allowsKey = false
        window?.ignoresMouseEvents = true
        window?.resignKey()
        yieldToRecordedApp()
        watchActivation()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.passingThrough, self.passGeneration == generation else { return }
            self.mountChromePanels()
        }
    }

    func endRecordingInteraction() {
        guard passingThrough else { return }
        passGeneration += 1
        let generation = passGeneration
        passingThrough = false
        stopWatchingActivation()
        window?.ignoresMouseEvents = false
        window?.allowsKey = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.passGeneration == generation else { return }
            self.unmountChromePanels(restoreToCanvas: self.window != nil)
            guard self.window != nil else { return }
            NSApp.activate()
            self.window?.makeKey()
            self.window?.makeFirstResponder(self.canvas)
            self.layout()
        }
    }

    func yieldToRecordedApp() {
        guard passingThrough, !yielding else { return }
        if let target = session.interactionTarget() {
            let front = NSWorkspace.shared.frontmostApplication
            if !NSApp.isActive, front?.processIdentifier == target.processIdentifier { return }
            yielding = true
            NSApp.yieldActivation(to: target)
            target.activate(from: .current, options: [])
            NSApp.deactivate()
            yielding = false
        } else if NSApp.isActive {
            yielding = true
            NSApp.deactivate()
            yielding = false
        }
    }

    func layout() {
        guard let window else { return }
        let onCanvas = topHost.superview === canvas
        func place(_ host: NSView, visible: Bool, frame: (CGSize) -> CGRect) {
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            let show = visible && size.width > 2 && size.height > 2
            if onCanvas {
                guard show else {
                    host.isHidden = true
                    return
                }
                host.isHidden = false
                host.frame = frame(size).offsetBy(dx: -window.frame.origin.x, dy: -window.frame.origin.y)
            } else if let item = chromeWindows.first(where: { $0.host === host }) {
                placeChrome(item, visible: show, tight: show ? frame(size) : .zero)
            }
        }
        place(topHost, visible: true) { size in
            let screen = anchorScreen()
            let visible = screen.visibleFrame
            var x = visible.midX - size.width / 2
            x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
            let y = visible.maxY - size.height - 8
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        place(annotationHost, visible: session.showsAnnotationBar) { size in
            guard let selection = session.selection else { return .zero }
            let screen = screenContaining(selection) ?? anchorScreen()
            var x = selection.midX - size.width / 2
            x = min(max(x, screen.frame.minX + 8), max(screen.frame.minX + 8, screen.frame.maxX - size.width - 8))
            var y = selection.maxY + 10
            if y + size.height > screen.visibleFrame.maxY - 8 {
                y = selection.minY - 10 - size.height
            }
            if y < screen.frame.minY + 8 {
                y = max(screen.frame.minY + 8, selection.maxY - size.height - 12)
            }
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        place(actionHost, visible: session.showsActionRail) { size in
            guard let selection = session.selection else { return .zero }
            let screen = screenContaining(selection) ?? anchorScreen()
            var x = selection.maxX + 12
            if x + size.width > screen.frame.maxX - 8 {
                x = selection.minX - 12 - size.width
            }
            if x < screen.frame.minX + 8 {
                x = screen.frame.maxX - size.width - 12
            }
            var y = selection.midY - size.height / 2
            y = min(max(y, screen.frame.minY + 8), max(screen.frame.minY + 8, screen.frame.maxY - size.height - 8))
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        canvas.syncTextEditor()
    }

    func focusTextEditor() {
        canvas.syncTextEditor()
        window?.makeFirstResponder(canvas.textEditor)
    }

    func endTextEditing() {
        canvas.endTextEditing()
    }

    func setClickThrough(_ enabled: Bool) {
        guard !passingThrough else { return }
        window?.ignoresMouseEvents = enabled
    }

    private let chromePad: CGFloat = 24

    private func mountChromePanels() {
        guard canvas != nil, chromeWindows.isEmpty else { return }
        for host in [topHost!, annotationHost!, actionHost!] as [NSView] {
            let panel = makeChromePanel()
            let root = PassThroughRoot(frame: .zero)
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor.clear.cgColor
            root.layer?.isOpaque = false
            panel.contentView = root
            host.removeFromSuperview()
            host.autoresizingMask = []
            root.addSubview(host)
            chromeWindows.append(ChromeWindow(panel: panel, host: host, root: root))
        }
        layout()
    }

    private func unmountChromePanels(restoreToCanvas: Bool) {
        let panels = chromeWindows
        chromeWindows = []
        for item in panels {
            item.host.removeFromSuperview()
            if restoreToCanvas {
                canvas?.addSubview(item.host)
            }
            item.panel.orderOut(nil)
            item.panel.close()
        }
    }

    private func placeChrome(_ item: ChromeWindow, visible: Bool, tight: CGRect) {
        guard visible, tight.width > 2, tight.height > 2 else {
            item.panel.orderOut(nil)
            return
        }
        let pad = chromePad
        item.host.isHidden = false
        item.host.frame = CGRect(x: pad, y: pad, width: tight.width, height: tight.height)
        let panelFrame = tight.insetBy(dx: -pad, dy: -pad)
        if item.panel.frame != panelFrame {
            item.panel.setFrame(panelFrame, display: true, animate: false)
        }
        if !item.panel.isVisible {
            item.panel.orderFrontRegardless()
        }
    }

    private func makeChromePanel() -> ChromePanel {
        let panel = ChromePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if window?.sharingType == NSWindow.SharingType.none {
            panel.sharingType = .none
        }
        _ = ChromeFirstMouse.install
        return panel
    }

    private func watchActivation() {
        stopWatchingActivation()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.yieldToRecordedApp()
        }
    }

    private func stopWatchingActivation() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func resizeToScreens() {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        window?.setFrame(union, display: true)
        layout()
        canvas?.needsDisplay = true
    }

    private func anchorScreen() -> NSScreen {
        if let selection = session.selection, let screen = screenContaining(selection) { return screen }
        return screenContaining(point: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

final class OverlayCanvas: NSView {
    let session: CaptureSession
    let textEditor = CaptureTextEditor()

    init(session: CaptureSession) {
        self.session = session
        super.init(frame: .zero)
    }

    func prepareTextEditor() {
        textEditor.isHidden = true
        textEditor.onTextChange = { [weak self] string in
            self?.session.updateEditingText(string)
        }
        if let host = subviews.first {
            addSubview(textEditor, positioned: .below, relativeTo: host)
        } else {
            addSubview(textEditor)
        }
    }

    func syncTextEditor() {
        guard let id = session.editingAnnotationID,
              let annotation = session.annotations.first(where: { $0.id == id }),
              let selection = session.selection,
              case let .text(rect, string, fontSize, font) = annotation.geometry else {
            if !textEditor.isHidden { endTextEditing() }
            return
        }
        let viewSelection = viewRect(selection)
        let frame = CGRect(
            x: viewSelection.minX + rect.minX,
            y: viewSelection.maxY - rect.maxY,
            width: max(rect.width, 48),
            height: max(rect.height, fontSize + TextLayout.inset * 2)
        )
        let color = NSColor(cgColor: annotation.color.cgColor) ?? .white
        textEditor.present(string: string, font: font.nsFont(size: fontSize), color: color, frame: frame)
    }

    func endTextEditing() {
        textEditor.suppressEnd = true
        textEditor.isHidden = true
        if window?.firstResponder === textEditor {
            window?.makeFirstResponder(self)
        }
        textEditor.suppressEnd = false
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: session.cursor(for: NSEvent.mouseLocation))
    }

    override func mouseDown(with event: NSEvent) {
        session.mouseDown(global: globalPoint(event), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) {
        session.mouseDragged(global: globalPoint(event))
        session.cursor(for: globalPoint(event)).set()
    }
    override func mouseUp(with event: NSEvent) { session.mouseUp(global: globalPoint(event)) }
    override func mouseMoved(with event: NSEvent) {
        session.mouseMoved(global: globalPoint(event))
        session.cursor(for: globalPoint(event)).set()
    }
    override func rightMouseDown(with event: NSEvent) { session.cancel() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        drawDim(context)
        drawCapture(context)
        drawAnnotations(context)
        drawChrome(context)
        context.restoreGState()
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let origin = window?.frame.origin ?? .zero
        return CGPoint(x: local.x + origin.x, y: local.y + origin.y)
    }

    private func viewRect(_ global: CGRect) -> CGRect {
        let origin = window?.frame.origin ?? .zero
        return global.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private func viewPoint(_ global: CGPoint) -> CGPoint {
        let origin = window?.frame.origin ?? .zero
        return CGPoint(x: global.x - origin.x, y: global.y - origin.y)
    }

    private func hole() -> CGRect? {
        if let selection = session.selection { return viewRect(selection) }
        if session.phase == .targeting, let hover = session.hoverRect { return viewRect(hover) }
        return nil
    }

    private func drawDim(_ context: CGContext) {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole = hole() { path.addRect(hole) }
        context.addPath(path)
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fillPath(using: .evenOdd)
        guard let hole = hole() else { return }
        // Zero alpha lets the live screen show through, and the window server then
        // delivers those clicks to the app behind this overlay. A faint fill keeps
        // the pixels sharp while making the region receive the click.
        context.setFillColor(NSColor.black.withAlphaComponent(0.05).cgColor)
        context.fill(hole)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(3)
        context.stroke(hole)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.stroke(hole.insetBy(dx: 0.75, dy: 0.75))
    }

    private func drawCapture(_ context: CGContext) {
        // While framing, the hole stays transparent so the real screen stays sharp.
        // Drawing the snapshot back into the hole resamples it and softens the region.
        guard session.phase == .actions, let selection = session.selection else { return }
        guard let image = session.previewImage ?? session.baseImage else { return }
        context.interpolationQuality = .none
        context.draw(image, in: viewRect(selection))
    }

    private func drawAnnotations(_ context: CGContext) {
        guard session.phase != .actions, let selection = session.selection else { return }
        let items = session.annotations.filter { $0.id != session.editingAnnotationID }
        for annotation in items {
            draw(annotation, selection: selection, context: context, source: session.baseImage ?? session.referenceImage)
        }
        if let draft = session.draft {
            let source = session.previewImage ?? session.baseImage ?? session.referenceImage
            draw(draft, selection: selection, context: context, source: source)
        }
    }

    private func draw(_ annotation: Annotation, selection: CGRect, context: CGContext, source: CGImage?) {
        if case let .mosaic(points, brush, strength) = annotation.geometry {
            drawMosaic(points: points, brush: brush, strength: strength, selection: selection, context: context, source: source)
            return
        }
        let map = localToView(selection)
        AnnotationRenderer.draw(annotation, in: context, map: map, lineScale: 1)
    }

    private func drawMosaic(points: [CGPoint], brush: CGFloat, strength: CGFloat, selection: CGRect, context: CGContext, source: CGImage?) {
        let path = AnnotationRenderer.mosaicStrokePath(points: points, brush: brush, map: localToView(selection))
        if let source, let pixellated = session.pixelCache.image(
            from: source,
            blockPixels: strength * CGFloat(source.width) / max(selection.width, 1)
        ) {
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.interpolationQuality = .none
            context.draw(pixellated, in: viewRect(selection))
            context.restoreGState()
        } else {
            context.addPath(path)
            context.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            context.fillPath()
        }
    }

    private func drawChrome(_ context: CGContext) {
        guard let selection = session.selection else {
            if let label = session.hoverLabel, let hover = session.hoverRect {
                drawLabel(label, centeredAtX: viewRect(hover).midX, y: viewRect(hover).maxY + 8)
            }
            return
        }
        let viewSelection = viewRect(selection)
        if session.phase == .targeting || session.phase == .framing, session.target != .fullScreen {
            for handle in BoxHandle.allCases {
                let point = viewPoint(handle.point(in: selection, yDown: false))
                drawHandle(at: point, context: context, radius: 4.5)
            }
        }
        if let selected = session.annotations.first(where: { $0.id == session.selectedAnnotationID }),
           session.phase == .framing || session.phase == .recording {
            let map = localToView(selection)
            let bounds = selected.bounds()
            let corners = [
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.minX, y: bounds.maxY)
            ].map(map)
            let outline = CGMutablePath()
            if let first = corners.first {
                outline.move(to: first)
                corners.dropFirst().forEach { outline.addLine(to: $0) }
                outline.closeSubpath()
            }
            context.saveGState()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.addPath(outline)
            context.strokePath()
            context.restoreGState()
            switch selected.geometry {
            case let .line(a, b), let .arrow(a, b):
                drawHandle(at: map(a), context: context, radius: 4)
                drawHandle(at: map(b), context: context, radius: 4)
            default:
                for handle in BoxHandle.allCases {
                    drawHandle(at: map(handle.point(in: bounds, yDown: true)), context: context, radius: 4)
                }
            }
        }
        if let screen = screenContaining(selection) {
            let scale = screen.backingScaleFactor
            let text = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
            var y = viewSelection.minY - 26
            if y < 8 { y = viewSelection.minY + 8 }
            drawLabel(text, centeredAtX: viewSelection.midX, y: y)
        }
    }

    private func localToView(_ selection: CGRect) -> (CGPoint) -> CGPoint {
        let viewSelection = viewRect(selection)
        return { local in
            CGPoint(x: viewSelection.minX + local.x, y: viewSelection.maxY - local.y)
        }
    }

    private func drawHandle(at point: CGPoint, context: CGContext, radius: CGFloat) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawLabel(_ text: String, centeredAtX: CGFloat, y: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(
            x: centeredAtX - size.width / 2 - 8,
            y: y,
            width: size.width + 16,
            height: size.height + 8
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            at: CGPoint(x: rect.minX + 8, y: rect.minY + 4),
            withAttributes: attributes
        )
    }
}

final class CaptureTextEditor: NSTextView {
    var onTextChange: ((String) -> Void)?
    var suppressEnd = false
    private var applying = false

    convenience init() {
        let container = NSTextContainer(size: NSSize(width: 160, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        drawsBackground = true
        backgroundColor = NSColor.black.withAlphaComponent(0.42)
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        focusRingType = .none
        textContainerInset = NSSize(width: TextLayout.inset, height: TextLayout.inset)
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) { nil }

    func present(string: String, font: NSFont, color: NSColor, frame: CGRect) {
        applying = true
        if self.string != string { self.string = string }
        self.font = font
        textColor = color
        insertionPointColor = color
        typingAttributes = [
            .font: font,
            .foregroundColor: color
        ]
        self.frame = frame
        textContainer?.containerSize = NSSize(width: max(8, frame.width), height: .greatestFiniteMagnitude)
        isHidden = false
        applying = false
    }

    override func didChangeText() {
        super.didChangeText()
        guard !applying else { return }
        onTextChange?(string)
    }
}
