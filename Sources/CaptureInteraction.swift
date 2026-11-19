import AppKit

extension CaptureSession {
    func mouseMoved(global: CGPoint) {
        guard drag == nil else { return }
        if phase == .targeting {
            switch target {
            case .region:
                if hoverRect != nil { setHover(rect: nil, label: nil, window: nil) }
            case .window:
                let window = window(at: global)
                setHover(rect: window?.frame, label: window?.label, window: window)
            case .fullScreen:
                if let screen = screenContaining(point: global) {
                    setHover(rect: screen.frame, label: screen.localizedName, window: nil)
                }
            }
        }
        if let canvas = overlay?.canvas {
            canvas.window?.invalidateCursorRects(for: canvas)
        }
    }

    func mouseDown(global: CGPoint, clickCount: Int = 1) {
        isSaveMenuOpen = false
        guard phase == .targeting || phase == .framing || phase == .recording else { return }

        if (phase == .framing || phase == .recording), clickCount >= 2, let id = textAnnotationID(at: global) {
            beginTextEditing(id)
            return
        }
        if editingAnnotationID != nil {
            commitTextEditing()
        }

        if phase == .recording {
            _ = beginAnnotationInteraction(global, allowNewShape: true)
            return
        }

        if phase == .targeting {
            switch target {
            case .region:
                guard let screen = screenContaining(point: global) ?? NSScreen.main else { return }
                if let selection, let handle = selectionHandle(at: global, selection: selection) {
                    drag = .resizeSelection(handle: handle, start: selection, screen: screenContaining(selection) ?? screen)
                    isAdjustingFrame = true
                } else {
                    drag = .newSelection(anchor: global, screen: screen, previous: selection)
                }
            case .window:
                if let window = window(at: global) ?? hoveredWindow { commitWindow(window) }
            case .fullScreen:
                if let screen = screenContaining(point: global) { commitScreen(screen) }
            }
            refresh()
            return
        }

        guard let selection else { return }
        if target != .fullScreen, let handle = selectionHandle(at: global, selection: selection) {
            let screen = screenContaining(selection) ?? NSScreen.main!
            drag = .resizeSelection(handle: handle, start: selection, screen: screen)
            isAdjustingFrame = true
            preferLiveAnnotations = true
            refresh()
            return
        }
        if selection.contains(global), target != .fullScreen {
            if beginAnnotationInteraction(global, allowNewShape: true) { return }
            if tool == .select {
                let screen = screenContaining(selection) ?? NSScreen.main!
                drag = .moveSelection(start: selection, anchor: global, screen: screen)
                isAdjustingFrame = true
                preferLiveAnnotations = true
                refresh()
            }
        }
    }

    func mouseDragged(global: CGPoint) {
        switch drag {
        case let .newSelection(anchor, screen, _):
            let rect = CGRect(x: anchor.x, y: anchor.y, width: global.x - anchor.x, height: global.y - anchor.y)
                .standardized
                .intersection(screen.frame)
            if rect.width >= 1, rect.height >= 1 { selection = rect }
        case let .moveSelection(start, anchor, screen):
            let moved = start.offsetBy(dx: global.x - anchor.x, dy: global.y - anchor.y)
            selection = clampOrigin(moved, inside: screen.frame)
        case let .resizeSelection(handle, start, screen):
            let resized = handle.resized(start, to: global, yDown: false, minimum: 12).intersection(screen.frame)
            if resized.width >= 8, resized.height >= 8 { selection = resized }
        case let .newShape(origin):
            guard let selection else { break }
            let local = SelectionSpace.local(fromGlobal: global, selection: selection)
            updateDraft(from: origin, to: clamp(local, to: selection.size))
        case let .moveShape(id, start, anchor):
            guard let selection, let index = annotations.firstIndex(where: { $0.id == id }) else { break }
            let local = SelectionSpace.local(fromGlobal: global, selection: selection)
            let delta = CGPoint(x: local.x - anchor.x, y: local.y - anchor.y)
            annotations[index] = start.translated(by: delta, limit: selection.size)
        case let .resizeShape(id, handle, start):
            guard let selection, let index = annotations.firstIndex(where: { $0.id == id }) else { break }
            let local = SelectionSpace.local(fromGlobal: global, selection: selection)
            annotations[index] = start.resized(handle: handle, to: local, limit: selection.size)
        case let .lineEnd(id, isStart, start):
            guard let selection, let index = annotations.firstIndex(where: { $0.id == id }) else { break }
            let local = SelectionSpace.local(fromGlobal: global, selection: selection)
            annotations[index] = start.withEndpoint(isStart: isStart, point: local, limit: selection.size)
        case nil:
            break
        }
        syncRecorder()
        refresh()
    }

    func mouseUp(global: CGPoint) {
        let finished = drag
        drag = nil
        switch finished {
        case let .newSelection(_, _, previous):
            isAdjustingFrame = false
            preferLiveAnnotations = false
            guard let selection, selection.width >= 8, selection.height >= 8 else {
                self.selection = previous
                if previous == nil { phase = .targeting }
                refresh()
                return
            }
            if previous != selection {
                annotations = []
                clearUndo()
                draft = nil
                selectedAnnotationID = nil
                baseImage = nil
                previewImage = nil
                referenceImage = nil
            }
            phase = .framing
            retakeAfterFrameChange()
        case .moveSelection, .resizeSelection:
            isAdjustingFrame = false
            preferLiveAnnotations = false
            if phase == .targeting { phase = .framing }
            retakeAfterFrameChange()
        case .newShape:
            commitDraft()
        case .moveShape, .resizeShape, .lineEnd:
            preferLiveAnnotations = false
            if let selectedAnnotationID { selectAnnotation(selectedAnnotationID) }
            rebuildPreview()
            syncRecorder()
        case nil:
            break
        }
        refresh()
    }

    private func beginAnnotationInteraction(_ global: CGPoint, allowNewShape: Bool) -> Bool {
        guard let selection, selection.contains(global), target != .fullScreen else { return false }
        let local = SelectionSpace.local(fromGlobal: global, selection: selection)
        if let hit = hitTestAnnotations(annotations, selectedID: selectedAnnotationID, point: local) {
            switch hit {
            case let .body(id):
                guard let annotation = annotations.first(where: { $0.id == id }) else { return true }
                if tool == .text, annotation.tool == .text {
                    beginTextEditing(id)
                    return true
                }
                pushUndo()
                selectAnnotation(id)
                preferLiveAnnotations = true
                drag = .moveShape(id: id, start: annotation, anchor: local)
            case let .box(id, handle):
                guard let annotation = annotations.first(where: { $0.id == id }) else { return true }
                pushUndo()
                selectAnnotation(id)
                preferLiveAnnotations = true
                drag = .resizeShape(id: id, handle: handle, start: annotation)
            case let .endpoint(id, isStart):
                guard let annotation = annotations.first(where: { $0.id == id }) else { return true }
                pushUndo()
                selectAnnotation(id)
                preferLiveAnnotations = true
                drag = .lineEnd(id: id, isStart: isStart, start: annotation)
            }
            refresh()
            return true
        }
        guard allowNewShape, tool != .select, phase != .actions else {
            if tool == .select { selectedAnnotationID = nil }
            return false
        }
        selectedAnnotationID = nil
        let origin = clamp(local, to: selection.size)
        switch tool {
        case .rectangle:
            draft = Annotation(geometry: .rectangle(.init(origin: origin, size: .zero)), color: style.color, lineWidth: style.lineWidth, filled: style.filled)
        case .ellipse:
            draft = Annotation(geometry: .ellipse(.init(origin: origin, size: .zero)), color: style.color, lineWidth: style.lineWidth, filled: style.filled)
        case .line:
            draft = Annotation(geometry: .line(origin, origin), color: style.color, lineWidth: style.lineWidth, filled: false)
        case .arrow:
            draft = Annotation(geometry: .arrow(origin, origin), color: style.color, lineWidth: style.lineWidth, filled: false)
        case .mosaic:
            draft = Annotation(geometry: .mosaic(points: [origin], brush: style.brushWidth, strength: style.mosaicStrength), color: style.color, lineWidth: style.brushWidth, filled: false)
        case .text:
            placeText(at: origin)
            return true
        case .select:
            return false
        }
        preferLiveAnnotations = true
        drag = .newShape(origin: origin)
        refresh()
        return true
    }

    private func updateDraft(from origin: CGPoint, to local: CGPoint) {
        guard var draft else { return }
        switch tool {
        case .rectangle:
            draft.geometry = .rectangle(rect(from: origin, to: local))
        case .ellipse:
            draft.geometry = .ellipse(rect(from: origin, to: local))
        case .line:
            draft.geometry = .line(origin, local)
        case .arrow:
            draft.geometry = .arrow(origin, local)
        case .mosaic:
            if case .mosaic(var points, let brush, let strength) = draft.geometry {
                if let last = points.last, hypot(last.x - local.x, last.y - local.y) >= 1.5 {
                    points.append(local)
                }
                draft.geometry = .mosaic(points: points, brush: brush, strength: strength)
            }
        case .text, .select:
            break
        }
        self.draft = draft
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func textAnnotationID(at global: CGPoint) -> UUID? {
        guard let selection, selection.contains(global) else { return nil }
        let local = SelectionSpace.local(fromGlobal: global, selection: selection)
        guard case let .body(id) = hitTestAnnotations(annotations, selectedID: selectedAnnotationID, point: local),
              annotations.first(where: { $0.id == id })?.tool == .text else { return nil }
        return id
    }

}
