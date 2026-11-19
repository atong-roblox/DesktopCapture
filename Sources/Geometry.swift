import AppKit

enum BoxHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    static let hitOrder: [BoxHandle] = [
        .topLeft, .topRight, .bottomLeft, .bottomRight, .top, .bottom, .left, .right
    ]

    func point(in rect: CGRect, yDown: Bool) -> CGPoint {
        let top = yDown ? rect.minY : rect.maxY
        let bottom = yDown ? rect.maxY : rect.minY
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: top)
        case .top: return CGPoint(x: rect.midX, y: top)
        case .topRight: return CGPoint(x: rect.maxX, y: top)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: bottom)
        case .bottom: return CGPoint(x: rect.midX, y: bottom)
        case .bottomRight: return CGPoint(x: rect.maxX, y: bottom)
        }
    }

    func resized(_ rect: CGRect, to point: CGPoint, yDown: Bool, minimum: CGFloat) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch self {
        case .left, .topLeft, .bottomLeft:
            minX = min(point.x, maxX - minimum)
        case .right, .topRight, .bottomRight:
            maxX = max(point.x, minX + minimum)
        default:
            break
        }
        let movesTop = self == .top || self == .topLeft || self == .topRight
        let movesBottom = self == .bottom || self == .bottomLeft || self == .bottomRight
        if yDown {
            if movesTop { minY = min(point.y, maxY - minimum) }
            if movesBottom { maxY = max(point.y, minY + minimum) }
        } else {
            if movesTop { maxY = max(point.y, minY + minimum) }
            if movesBottom { minY = min(point.y, maxY - minimum) }
        }
        return CGRect(x: minX, y: minY, width: max(minimum, maxX - minX), height: max(minimum, maxY - minY))
    }

    var resizeCursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch self {
        case .top: position = .top
        case .bottom: position = .bottom
        case .left: position = .left
        case .right: position = .right
        case .topLeft: position = .topLeft
        case .topRight: position = .topRight
        case .bottomLeft: position = .bottomLeft
        case .bottomRight: position = .bottomRight
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}

enum DisplaySpace {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// CGWindow / display space uses a top-left origin on the primary display, y down.
    static func appKitRect(fromDisplay rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Points relative to a display's top-left, y down. This is `SCStreamConfiguration.sourceRect`.
    static func sourceRect(forAppKitRect rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

enum SelectionSpace {
    /// AppKit global point → selection-local point, origin at the selection's top-left, y down.
    static func local(fromGlobal point: CGPoint, selection: CGRect) -> CGPoint {
        CGPoint(x: point.x - selection.minX, y: selection.maxY - point.y)
    }

    static func global(fromLocal point: CGPoint, selection: CGRect) -> CGPoint {
        CGPoint(x: selection.minX + point.x, y: selection.maxY - point.y)
    }
}

func distance(_ point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    if lengthSquared == 0 { return hypot(point.x - start.x, point.y - start.y) }
    let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
    return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
}

func screenContaining(_ rect: CGRect) -> NSScreen? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
}

func screenContaining(point: CGPoint) -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

func clampOrigin(_ rect: CGRect, inside screen: CGRect) -> CGRect {
    var result = rect
    if result.width > screen.width { result.size.width = screen.width }
    if result.height > screen.height { result.size.height = screen.height }
    if result.minX < screen.minX { result.origin.x = screen.minX }
    if result.minY < screen.minY { result.origin.y = screen.minY }
    if result.maxX > screen.maxX { result.origin.x = screen.maxX - result.width }
    if result.maxY > screen.maxY { result.origin.y = screen.maxY - result.height }
    return result
}

func clamp(_ point: CGPoint, to size: CGSize) -> CGPoint {
    CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
}

func formatDuration(_ time: TimeInterval) -> String {
    let seconds = max(0, Int(time.rounded(.down)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
