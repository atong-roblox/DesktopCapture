import AppKit
import Combine
import SwiftUI

enum CaptureTarget: String, CaseIterable, Identifiable {
    case region, window, fullScreen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: "Region"
        case .window: "Window"
        case .fullScreen: "Full Screen"
        }
    }
    var symbol: String {
        switch self {
        case .region: "rectangle.dashed"
        case .window: "macwindow"
        case .fullScreen: "display"
        }
    }
}

private enum ExportRequest {
    case recent(URL)
    case panel
    case copy
    case pin
}

enum CaptureKind: String, CaseIterable, Identifiable {
    case image, gif, video
    var id: String { rawValue }
    var title: String {
        switch self {
        case .image: "Image"
        case .gif: "GIF"
        case .video: "Video"
        }
    }
    var symbol: String? {
        switch self {
        case .image: "photo"
        case .gif: nil
        case .video: "video"
        }
    }
}

enum SessionPhase {
    case targeting, framing, recording, finalizing, actions, scrolling
}

final class CaptureSession: ObservableObject {
    enum Drag {
        case newSelection(anchor: CGPoint, screen: NSScreen, previous: CGRect?)
        case moveSelection(start: CGRect, anchor: CGPoint, screen: NSScreen)
        case resizeSelection(handle: BoxHandle, start: CGRect, screen: NSScreen)
        case newShape(origin: CGPoint)
        case moveShape(id: UUID, start: Annotation, anchor: CGPoint)
        case resizeShape(id: UUID, handle: BoxHandle, start: Annotation)
        case lineEnd(id: UUID, isStart: Bool, start: Annotation)
    }

    @Published var target: CaptureTarget = .region
    @Published var kind: CaptureKind = .image
    @Published var phase: SessionPhase = .targeting
    @Published var tool: AnnotationTool = .select
    @Published var style = AnnotationStyle()
    @Published var selectedAnnotationID: UUID?
    @Published var recordingTime: TimeInterval = 0
    @Published var isSaveMenuOpen = false
    @Published var recentLocations: [URL] = []
    @Published var banner: String?
    @Published var selection: CGRect?

    private(set) var hoverRect: CGRect?
    private(set) var hoverLabel: String?
    private(set) var hoveredWindow: ListedWindow?
    var annotations: [Annotation] = []
    var draft: Annotation?
    var baseImage: CGImage?
    var previewImage: CGImage?
    var referenceImage: CGImage?
    var preferLiveAnnotations = false
    var isAdjustingFrame = false
    var media: CapturedPiece?
    var drag: Drag?
    var hotkeyAvailable = true

    let pixelCache = PixelCache()
    private(set) var overlay: OverlayController?
    private var recorder: RegionRecorder?
    private var recordingTimer: Timer?
    private var recordingStarted = Date()
    private var undoStack: [[Annotation]] = []
    private var snapshotGeneration = 0
    private var previewGeneration = 0
    private var snapshotInFlight = false
    private var pendingFinish = false
    private var pendingExport: ExportRequest?
    private var isStartingRecording = false
    private var stopAfterStart = false
    private var windowCache: [ListedWindow] = []
    private var windowCacheTime: TimeInterval = 0
    private var keyMonitor: Any?
    private var previousFrontmostApp: NSRunningApplication?
    private var suppressingForwardedKey = false
    private var isOpen = false
    private var copiedMovie = false
    private var scrollRunner: AutoScrollRunner?
    private(set) var editingAnnotationID: UUID?

    var controlsEnabled: Bool { phase == .targeting || phase == .framing }

    var showsAnnotationBar: Bool {
        guard let selection, selection.width >= 8, selection.height >= 8 else { return false }
        return phase == .framing || phase == .recording
    }

    var showsDrawingTools: Bool { target != .fullScreen }

    var showsFinishControl: Bool {
        if phase == .recording || kind != .image { return true }
        return target != .region
    }

    var showsAutoScroll: Bool {
        kind == .image && target == .region && phase == .framing
    }

    var showsActionRail: Bool {
        guard let selection, selection.width >= 8, selection.height >= 8 else { return false }
        if kind == .image, target == .region, phase == .framing || phase == .finalizing || phase == .actions {
            return true
        }
        return phase == .actions && media != nil
    }

    var optionTool: AnnotationTool {
        if let selectedAnnotationID, let annotation = annotations.first(where: { $0.id == selectedAnnotationID }) {
            return annotation.tool
        }
        return tool
    }

    var statusLine: String {
        if let banner, !banner.isEmpty { return banner }
        switch phase {
        case .targeting:
            switch target {
            case .region: return "Drag to select a region"
            case .window: return "Click a window"
            case .fullScreen: return "Click a screen"
            }
        case .framing:
            if tool == .text { return "Click to add text  ·  double-click to edit" }
            if kind == .image {
                return target == .region ? "Annotate, save, or auto-scroll" : "Annotate, then press Return"
            }
            if kind == .gif { return "Annotate, then record  ·  12s max" }
            return "Annotate, then record"
        case .recording:
            return "\(formatDuration(recordingTime))  ·  Click Stop to finish"
        case .finalizing:
            return "Preparing…"
        case .actions:
            return kind == .image ? "Save, copy, or pin  ·  Esc to edit" : "Save, copy, or pin  ·  Esc to redo"
        case .scrolling:
            return "Pointer scrolls the content  ·  Done to finish"
        }
    }

    func begin(force: Bool = false) {
        if isOpen {
            if phase == .recording { stopRecording() }
            return
        }
        if !force && !CGPreflightScreenCaptureAccess() {
            PermissionWindow.show()
            return
        }
        isOpen = true
        resetTake()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            previousFrontmostApp = front
        }
        let controller = OverlayController(session: self)
        overlay = controller
        controller.show()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if self.phase == .recording {
                return self.forwardRecordingKey(event)
            }
            guard event.type == .keyDown else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    func setTarget(_ target: CaptureTarget) {
        guard controlsEnabled, self.target != target else { return }
        self.target = target
        discardMedia()
        resetTake()
    }

    func setKind(_ kind: CaptureKind) {
        guard controlsEnabled, self.kind != kind else { return }
        self.kind = kind
        guard phase == .framing || phase == .actions else { return }
        if phase == .actions { discardMedia() }
        phase = .framing
        if kind == .image {
            previewImage = nil
            takeSnapshot()
        } else {
            baseImage = nil
            previewImage = nil
            refresh()
        }
    }

    func setTool(_ tool: AnnotationTool) {
        if tool != .text { commitTextEditing() }
        self.tool = tool
        if tool != .select, let selectedAnnotationID,
           let annotation = annotations.first(where: { $0.id == selectedAnnotationID }),
           annotation.tool != tool {
            self.selectedAnnotationID = nil
        }
    }

    func setColor(_ color: AnnotColor) { updateStyle { $0.color = color } }
    func setLineWidth(_ width: CGFloat) { updateStyle { $0.lineWidth = width } }
    func setFilled(_ filled: Bool) { updateStyle { $0.filled = filled } }
    func setMosaicStrength(_ strength: CGFloat) { updateStyle { $0.mosaicStrength = strength } }
    func setBrushWidth(_ width: CGFloat) { updateStyle { $0.brushWidth = width } }
    func setFontSize(_ size: CGFloat) { updateStyle { $0.fontSize = size } }
    func setTextFont(_ font: TextFont) { updateStyle { $0.font = font } }

    func done() {
        commitTextEditing()
        finishImage()
    }

    func toggleRecord() {
        commitTextEditing()
        if phase == .recording { stopRecording() } else { startRecording() }
    }

    func toggleSaveMenu() {
        commitTextEditing()
        recentLocations = RecentLocations.load()
        if recentLocations.isEmpty {
            requestExport(.panel)
        } else {
            isSaveMenuOpen.toggle()
        }
    }

    func saveToRecent(_ directory: URL) {
        isSaveMenuOpen = false
        requestExport(.recent(directory))
    }

    func chooseSaveLocation() {
        isSaveMenuOpen = false
        requestExport(.panel)
    }

    func copy() {
        isSaveMenuOpen = false
        requestExport(.copy)
    }

    func pin() {
        isSaveMenuOpen = false
        requestExport(.pin)
    }

    private func requestExport(_ request: ExportRequest) {
        commitTextEditing()
        if media == nil, kind == .image, phase == .framing || phase == .finalizing {
            pendingExport = request
            if phase == .framing { finishImage() }
            return
        }
        guard let media else { return }
        performExport(request, media: media)
    }

    private func performExport(_ request: ExportRequest, media: CapturedPiece) {
        switch request {
        case .recent(let directory):
            do {
                _ = try Exporter.quickSave(media, directory: directory)
                end(deleteMovie: !copiedMovie)
            } catch {
                banner = error.localizedDescription
            }
        case .panel:
            guard let window = overlay?.window else { return }
            isSaveMenuOpen = false
            let previous = window.level
            window.level = .normal
            defer { window.level = previous }
            guard let url = Exporter.presentSavePanel(for: media) else { return }
            do {
                try Exporter.write(media, to: url)
                RecentLocations.remember(url.deletingLastPathComponent())
                end(deleteMovie: !copiedMovie)
            } catch {
                banner = error.localizedDescription
            }
        case .copy:
            do {
                try Exporter.copyToPasteboard(media)
                if case .movie = media { copiedMovie = true }
                end(deleteMovie: false)
            } catch {
                banner = error.localizedDescription
            }
        case .pin:
            let piece = media
            self.media = nil
            end(deleteMovie: false)
            PinBoard.shared.present(piece)
        }
    }

    func startAutoScroll() {
        guard showsAutoScroll, scrollRunner == nil else { return }
        commitTextEditing()
        isSaveMenuOpen = false
        guard AccessibilityPrompt.isTrusted || AccessibilityPrompt.ask() else {
            banner = "Turn on Capture in Accessibility Settings, then try Auto Scroll again."
            refresh()
            return
        }
        banner = nil
        phase = .scrolling
        overlay?.setClickThrough(true)
        let runner = AutoScrollRunner(session: self)
        scrollRunner = runner
        runner.start()
    }

    func finishAutoScroll() {
        guard phase == .scrolling else { return }
        let image = scrollRunner?.stop()
        scrollRunner = nil
        overlay?.setClickThrough(false)
        guard let image else {
            phase = .framing
            banner = nil
            refresh()
            return
        }
        end(deleteMovie: false)
        PinBoard.shared.present(.still(image), mode: .scroll)
    }

    func abortAutoScroll() {
        guard phase == .scrolling else { return }
        scrollRunner?.cancel()
        scrollRunner = nil
        overlay?.setClickThrough(false)
        phase = .framing
        banner = nil
        refresh()
    }

    func cancel() {
        scrollRunner?.cancel()
        scrollRunner = nil
        overlay?.setClickThrough(false)
        editingAnnotationID = nil
        overlay?.endTextEditing()
        let active = recorder
        recorder = nil
        isStartingRecording = false
        discardMedia()
        end(deleteMovie: false)
        if let active {
            Task {
                if let product = try? await active.stop(), case .video(let url) = product {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    func placeText(at local: CGPoint) {
        guard let selection, phase == .framing || phase == .recording else { return }
        commitTextEditing()
        pushUndo()
        let width = min(240, max(120, selection.width * 0.35))
        let box = TextLayout.box(origin: local, width: width, string: "", font: style.font, fontSize: style.fontSize, limit: selection.size)
        let annotation = Annotation(
            geometry: .text(rect: box, string: "", fontSize: style.fontSize, font: style.font),
            color: style.color,
            lineWidth: style.lineWidth,
            filled: false
        )
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
        editingAnnotationID = annotation.id
        preferLiveAnnotations = true
        syncRecorder()
        refresh()
        overlay?.layout()
        overlay?.focusTextEditor()
    }

    func beginTextEditing(_ id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        if editingAnnotationID == id {
            overlay?.focusTextEditor()
            return
        }
        commitTextEditing()
        pushUndo()
        editingAnnotationID = id
        selectAnnotation(id)
        preferLiveAnnotations = true
        refresh()
        overlay?.layout()
        overlay?.focusTextEditor()
    }

    func updateEditingText(_ string: String) {
        guard let id = editingAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case let .text(rect, _, fontSize, font) = annotations[index].geometry else { return }
        let limit = selection?.size ?? CGSize(width: max(rect.width, 48), height: max(rect.maxY, fontSize * 2))
        let box = TextLayout.box(origin: rect.origin, width: rect.width, string: string, font: font, fontSize: fontSize, limit: limit)
        let updated = AnnotationGeometry.text(rect: box, string: string, fontSize: fontSize, font: font)
        if annotations[index].geometry == updated { return }
        annotations[index].geometry = updated
        preferLiveAnnotations = true
        syncRecorder()
        refresh()
        overlay?.layout()
    }

    func commitTextEditing() {
        guard let id = editingAnnotationID else { return }
        editingAnnotationID = nil
        overlay?.endTextEditing()
        if let index = annotations.firstIndex(where: { $0.id == id }),
           case let .text(rect, string, fontSize, font) = annotations[index].geometry {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                annotations.remove(at: index)
                if selectedAnnotationID == id { selectedAnnotationID = nil }
            } else {
                let limit = selection?.size ?? CGSize(width: rect.width, height: max(rect.maxY, 1))
                let box = TextLayout.box(origin: rect.origin, width: rect.width, string: string, font: font, fontSize: fontSize, limit: limit)
                annotations[index].geometry = .text(rect: box, string: string, fontSize: fontSize, font: font)
            }
        }
        preferLiveAnnotations = false
        rebuildPreview()
        syncRecorder()
        refresh()
        overlay?.layout()
    }

    func refresh() {
        overlay?.canvas.needsDisplay = true
    }

    func cursor(for global: CGPoint) -> NSCursor {
        switch drag {
        case .moveSelection, .moveShape:
            return .closedHand
        case .resizeSelection(let handle, _, _), .resizeShape(_, let handle, _):
            return handle.resizeCursor
        case .lineEnd, .newSelection, .newShape:
            return .crosshair
        case nil:
            break
        }
        if let selection, phase == .framing || phase == .targeting, target != .fullScreen,
           phase != .recording, let handle = selectionHandle(at: global, selection: selection) {
            return handle.resizeCursor
        }
        if let selection, (phase == .framing || phase == .recording), selection.contains(global), target != .fullScreen {
            let local = SelectionSpace.local(fromGlobal: global, selection: selection)
            if let hit = hitTestAnnotations(annotations, selectedID: selectedAnnotationID, point: local) {
                switch hit {
                case .box(_, let handle): return handle.resizeCursor
                case .endpoint: return .crosshair
                case .body(let id):
                    if tool == .text, annotations.first(where: { $0.id == id })?.tool == .text { return .iBeam }
                    return .openHand
                }
            }
            if tool == .text { return .iBeam }
        if tool != .select { return .crosshair }
        }
        if phase == .targeting && target == .region { return .crosshair }
        return .arrow
    }

    func selectionHandle(at global: CGPoint, selection: CGRect) -> BoxHandle? {
        for handle in BoxHandle.hitOrder {
            let point = handle.point(in: selection, yDown: false)
            if hypot(point.x - global.x, point.y - global.y) <= 9 { return handle }
        }
        return nil
    }

    fileprivate func windowsUnderCursor() -> [ListedWindow] {
        let now = Date.timeIntervalSinceReferenceDate
        if now - windowCacheTime > 0.12 {
            windowCache = ScreenGrabber.listedWindows()
            windowCacheTime = now
        }
        return windowCache
    }

    func window(at global: CGPoint) -> ListedWindow? {
        windowsUnderCursor().first { $0.frame.contains(global) }
    }

    /// The app the user is recording, so keystrokes and clicks can land there.
    func interactionTarget() -> NSRunningApplication? {
        let point: CGPoint
        if let selection {
            point = CGPoint(x: selection.midX, y: selection.midY)
        } else {
            point = NSEvent.mouseLocation
        }
        if let pid = window(at: point)?.ownerPID, pid > 0, pid != getpid(),
           let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            return app
        }
        if let previousFrontmostApp,
           previousFrontmostApp.processIdentifier != getpid(),
           !previousFrontmostApp.isTerminated {
            return previousFrontmostApp
        }
        return nil
    }

    func setHover(rect: CGRect?, label: String?, window: ListedWindow?) {
        hoverRect = rect
        hoverLabel = label
        hoveredWindow = window
        refresh()
    }

    func commitWindow(_ window: ListedWindow) {
        selection = window.frame
        hoveredWindow = nil
        hoverRect = nil
        hoverLabel = nil
        phase = .framing
        if kind == .image { takeSnapshot() } else { takeReferenceSnapshot() }
    }

    func commitScreen(_ screen: NSScreen) {
        selection = screen.frame
        hoverRect = nil
        hoverLabel = nil
        if kind == .image {
            phase = .finalizing
            banner = "Capturing…"
            pendingFinish = true
            takeSnapshot()
        } else {
            phase = .framing
            takeReferenceSnapshot()
        }
    }

    func selectAnnotation(_ id: UUID?) {
        selectedAnnotationID = id
        guard let id, let annotation = annotations.first(where: { $0.id == id }) else { return }
        var next = style
        next.color = annotation.color
        next.lineWidth = annotation.lineWidth
        next.filled = annotation.filled
        if case let .mosaic(_, brush, strength) = annotation.geometry {
            next.brushWidth = brush
            next.mosaicStrength = strength
        }
        if case let .text(_, _, fontSize, font) = annotation.geometry {
            next.fontSize = fontSize
            next.font = font
        }
        style = next
    }

    func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    func commitDraft() {
        guard let draft else { return }
        let bigEnough: Bool
        switch draft.geometry {
        case let .rectangle(rect), let .ellipse(rect):
            bigEnough = rect.width >= 4 || rect.height >= 4
        case let .line(a, b), let .arrow(a, b):
            bigEnough = hypot(a.x - b.x, a.y - b.y) >= 4
        case let .mosaic(points, _, _):
            bigEnough = points.count >= 2
        case let .text(_, string, _, _):
            bigEnough = !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.draft = nil
        guard bigEnough else {
            refresh()
            return
        }
        pushUndo()
        annotations.append(draft)
        preferLiveAnnotations = false
        selectAnnotation(draft.id)
        tool = .select
        rebuildPreview()
        syncRecorder()
        refresh()
    }

    func syncRecorder() {
        var items = annotations
        if let draft { items.append(draft) }
        recorder?.setAnnotations(items)
    }

    func clearUndo() {
        undoStack.removeAll()
    }

    func retakeAfterFrameChange() {
        if kind == .image {
            baseImage = nil
            previewImage = nil
            takeSnapshot()
        } else {
            referenceImage = nil
            takeReferenceSnapshot()
        }
    }

    private func updateStyle(_ change: (inout AnnotationStyle) -> Void) {
        var next = style
        change(&next)
        style = next
        guard let selectedAnnotationID, let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }) else { return }
        annotations[index].color = next.color
        annotations[index].lineWidth = next.lineWidth
        annotations[index].filled = next.filled
        if case let .mosaic(points, _, _) = annotations[index].geometry {
            annotations[index].geometry = .mosaic(points: points, brush: next.brushWidth, strength: next.mosaicStrength)
        }
        if case let .text(rect, string, _, _) = annotations[index].geometry {
            let limit = selection?.size ?? CGSize(width: rect.width, height: rect.maxY)
            let box = TextLayout.box(origin: rect.origin, width: rect.width, string: string, font: next.font, fontSize: next.fontSize, limit: limit)
            annotations[index].geometry = .text(rect: box, string: string, fontSize: next.fontSize, font: next.font)
        }
        rebuildPreview()
        syncRecorder()
        refresh()
    }

    private func finishImage() {
        guard let selection, selection.width >= 8, selection.height >= 8 else { return }
        if baseImage == nil {
            pendingFinish = true
            banner = "Capturing…"
            if !snapshotInFlight { takeSnapshot() }
            return
        }
        phase = .finalizing
        banner = "Preparing…"
        let base = baseImage!
        let items = annotations
        let size = selection.size
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Compositor.composite(base: base, annotations: items, pointSize: size)
            DispatchQueue.main.async {
                guard self.phase == .finalizing else { return }
                self.media = .still(image)
                self.previewImage = image
                self.banner = nil
                self.isSaveMenuOpen = false
                let request = self.pendingExport
                self.pendingExport = nil
                if let request {
                    self.performExport(request, media: .still(image))
                } else {
                    self.phase = .actions
                    self.recentLocations = RecentLocations.load()
                    self.refresh()
                }
            }
        }
    }

    private func startRecording() {
        guard kind != .image, phase == .framing, recorder == nil, !isStartingRecording,
              let selection, selection.width >= 8, let screen = screenContaining(selection) else { return }
        isStartingRecording = true
        stopAfterStart = false
        phase = .recording
        banner = nil
        recordingTime = 0
        overlay?.beginRecordingInteraction()
        let recorder = RegionRecorder(kind: kind)
        self.recorder = recorder
        syncRecorder()
        let rect = selection
        Task {
            do {
                try await recorder.start(appKitRect: rect, screen: screen)
                DispatchQueue.main.async {
                    self.isStartingRecording = false
                    guard self.recorder === recorder else { return }
                    if self.stopAfterStart || self.phase != .recording {
                        self.stopRecording()
                    } else {
                        self.beginTimer()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isStartingRecording = false
                    if self.recorder === recorder { self.recorder = nil }
                    if self.phase == .recording { self.phase = .framing }
                    self.overlay?.endRecordingInteraction()
                    self.fail(error)
                }
            }
        }
    }

    private func stopRecording() {
        if isStartingRecording {
            stopAfterStart = true
            return
        }
        overlay?.endRecordingInteraction()
        guard let recorder else { return }
        self.recorder = nil
        phase = .finalizing
        banner = "Preparing…"
        recordingTimer?.invalidate()
        recordingTimer = nil
        let recordedKind = kind
        Task {
            do {
                let product = try await recorder.stop()
                let piece = try piece(from: product)
                DispatchQueue.main.async {
                    self.media = piece
                    if let poster = piece.posterImage, recordedKind == .gif {
                        self.previewImage = poster
                        self.baseImage = poster
                    }
                    self.phase = .actions
                    self.banner = nil
                    self.recentLocations = RecentLocations.load()
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .framing
                    self.fail(error)
                }
            }
        }
    }

    private func beginTimer() {
        recordingStarted = Date()
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.phase == .recording else { return }
            self.recordingTime = Date().timeIntervalSince(self.recordingStarted)
            let limit: TimeInterval = self.kind == .gif ? 12 : 180
            if self.recordingTime >= limit { self.stopRecording() }
        }
    }

    private func takeSnapshot() {
        guard let selection, let screen = screenContaining(selection) else { return }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        snapshotInFlight = true
        let rect = selection.intersection(screen.frame)
        let captureKind = kind
        Task {
            do {
                let image = try await ScreenGrabber.captureStill(appKitRect: rect, screen: screen, showsCursor: false)
                DispatchQueue.main.async {
                    guard generation == self.snapshotGeneration else { return }
                    self.snapshotInFlight = false
                    self.referenceImage = image
                    if captureKind == .image {
                        self.baseImage = image
                        self.rebuildPreview()
                    }
                    self.refresh()
                    if self.pendingFinish {
                        self.pendingFinish = false
                        self.finishImage()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.snapshotGeneration else { return }
                    self.snapshotInFlight = false
                    self.pendingFinish = false
                    self.pendingExport = nil
                    if self.phase == .finalizing { self.phase = .framing }
                    self.fail(error)
                }
            }
        }
    }

    private func takeReferenceSnapshot() {
        guard let selection, let screen = screenContaining(selection) else { return }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let rect = selection.intersection(screen.frame)
        Task {
            do {
                let image = try await ScreenGrabber.captureStill(appKitRect: rect, screen: screen, showsCursor: false)
                DispatchQueue.main.async {
                    guard generation == self.snapshotGeneration else { return }
                    self.referenceImage = image
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.snapshotGeneration else { return }
                    self.fail(error)
                }
            }
        }
    }

    func rebuildPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        guard kind == .image, let base = baseImage, let selection, selection.width > 1 else {
            if kind == .image { previewImage = nil }
            return
        }
        let items = annotations
        let size = selection.size
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Compositor.composite(base: base, annotations: items, pointSize: size)
            DispatchQueue.main.async {
                guard generation == self.previewGeneration else { return }
                self.previewImage = image
                self.refresh()
            }
        }
    }

    private func fail(_ error: Error) {
        captureLog(error.localizedDescription)
        banner = error.localizedDescription
        if permissionDenied(error) || !CGPreflightScreenCaptureAccess() {
            PermissionWindow.show()
        }
    }

    private func returnToEditing() {
        discardMedia()
        media = nil
        isSaveMenuOpen = false
        banner = nil
        if kind == .image {
            previewImage = nil
            rebuildPreview()
        } else {
            baseImage = nil
            previewImage = nil
        }
        phase = .framing
        refresh()
    }

    private func resetTake() {
        selection = nil
        hoverRect = nil
        hoverLabel = nil
        hoveredWindow = nil
        annotations = []
        draft = nil
        baseImage = nil
        previewImage = nil
        referenceImage = nil
        media = nil
        drag = nil
        undoStack = []
        selectedAnnotationID = nil
        editingAnnotationID = nil
        preferLiveAnnotations = false
        isAdjustingFrame = false
        pendingFinish = false
        pendingExport = nil
        isSaveMenuOpen = false
        banner = nil
        recordingTime = 0
        copiedMovie = false
        phase = .targeting
        snapshotGeneration += 1
        previewGeneration += 1
        refresh()
    }

    private func discardMedia() {
        if let media, case .movie(let url, _) = media, !copiedMovie {
            try? FileManager.default.removeItem(at: url)
        }
        media = nil
    }

    private func end(deleteMovie: Bool) {
        if deleteMovie, let media, case .movie(let url, _) = media {
            try? FileManager.default.removeItem(at: url)
        }
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        overlay?.close()
        overlay = nil
        resetTake()
        isOpen = false
    }

    /// While a GIF or video is recording, keys belong to the app on screen.
    /// Return and Escape still stop or cancel if focus never left Capture.
    private func forwardRecordingKey(_ event: NSEvent) -> NSEvent? {
        if suppressingForwardedKey { return nil }
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.forwardedKeyMarker {
            return nil
        }
        let wasActive = NSApp.isActive
        if wasActive {
            overlay?.yieldToRecordedApp()
        }
        if !NSApp.isActive, let cgEvent = event.cgEvent {
            cgEvent.setIntegerValueField(.eventSourceUserData, value: Self.forwardedKeyMarker)
            suppressingForwardedKey = true
            cgEvent.post(tap: .cghidEventTap)
            suppressingForwardedKey = false
            return nil
        }
        guard event.type == .keyDown else { return event }
        return handleKey(event) ? nil : event
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if editingAnnotationID != nil {
            if event.keyCode == 53 {
                commitTextEditing()
                return true
            }
            return false
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z", !flags.contains(.shift) {
            guard drag == nil, let previous = undoStack.popLast() else { return true }
            annotations = previous
            selectedAnnotationID = nil
            draft = nil
            preferLiveAnnotations = false
            rebuildPreview()
            syncRecorder()
            refresh()
            return true
        }
        switch event.keyCode {
        case 53:
            if isSaveMenuOpen {
                isSaveMenuOpen = false
                return true
            }
            if selectedAnnotationID != nil, phase == .framing || phase == .recording {
                selectedAnnotationID = nil
                refresh()
                return true
            }
            if phase == .scrolling {
                abortAutoScroll()
                return true
            }
            if phase == .actions {
                returnToEditing()
                return true
            }
            cancel()
            return true
        case 36, 76:
            confirmFromKeyboard()
            return true
        case 51, 117:
            deleteSelected()
            return true
        default:
            return false
        }
    }

    private func confirmFromKeyboard() {
        switch phase {
        case .targeting:
            if target == .window, let hoveredWindow { commitWindow(hoveredWindow) }
            if target == .fullScreen, let screen = screenContaining(point: NSEvent.mouseLocation) { commitScreen(screen) }
        case .framing:
            commitTextEditing()
            if kind == .image, target != .region { finishImage() }
            else if kind != .image { startRecording() }
        case .recording:
            stopRecording()
        case .scrolling:
            finishAutoScroll()
        case .finalizing, .actions:
            break
        }
    }

    private static let forwardedKeyMarker: Int64 = 0x4341_5054

    private func deleteSelected() {
        guard let selectedAnnotationID else { return }
        if editingAnnotationID == selectedAnnotationID {
            editingAnnotationID = nil
            overlay?.endTextEditing()
        }
        pushUndo()
        annotations.removeAll { $0.id == selectedAnnotationID }
        self.selectedAnnotationID = nil
        rebuildPreview()
        syncRecorder()
        refresh()
    }
}

private func piece(from product: RecordingProduct) throws -> CapturedPiece {
    switch product {
    case let .gif(frames, delay):
        guard let data = Exporter.encodeGIF(frames: frames, delay: delay) else {
            throw CaptureError.message("Couldn't encode the GIF.")
        }
        return .gif(data: data, frames: frames, frameDelay: delay)
    case let .video(url):
        return .movie(url, poster: nil)
    }
}

final class PixelCache {
    private var source: CGImage?
    private var block: CGFloat = -1
    private var output: CGImage?

    func image(from source: CGImage, blockPixels: CGFloat) -> CGImage? {
        let block = max(2, blockPixels.rounded())
        if self.source === source, self.block == block { return output }
        self.source = source
        self.block = block
        output = Compositor.pixellated(source, blockPixels: block)
        return output
    }
}

func captureLog(_ message: String) {
    fputs("Capture: \(message)\n", stderr)
}
