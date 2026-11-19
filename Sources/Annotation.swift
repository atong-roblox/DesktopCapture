import AppKit
import CoreGraphics
import CoreText
import Foundation

struct AnnotColor: Equatable, Identifiable {
    var r, g, b: CGFloat
    var id: String { "\(r)-\(g)-\(b)" }
    var name: String

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var halo: CGColor {
        luminance > 0.62
            ? CGColor(gray: 0, alpha: 0.82)
            : CGColor(gray: 1, alpha: 0.92)
    }

    static let presets: [AnnotColor] = [
        AnnotColor(r: 1, g: 1, b: 1, name: "White"),
        AnnotColor(r: 0.11, g: 0.11, b: 0.12, name: "Black"),
        AnnotColor(r: 1, g: 0.231, b: 0.188, name: "Red"),
        AnnotColor(r: 1, g: 0.584, b: 0, name: "Orange"),
        AnnotColor(r: 1, g: 0.8, b: 0, name: "Yellow"),
        AnnotColor(r: 0.204, g: 0.780, b: 0.349, name: "Green"),
        AnnotColor(r: 0.039, g: 0.518, b: 1, name: "Blue"),
        AnnotColor(r: 0.686, g: 0.322, b: 0.871, name: "Purple")
    ]

    static let `default` = presets[2]
}

enum TextFont: String, CaseIterable, Identifiable, Equatable {
    case sans, serif, mono, round

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        case .mono: "Mono"
        case .round: "Round"
        }
    }

    func nsFont(size: CGFloat) -> NSFont {
        let weight = NSFont.Weight.semibold
        switch self {
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .sans, .serif, .round:
            let design: NSFontDescriptor.SystemDesign = switch self {
            case .serif: .serif
            case .round: .rounded
            default: .default
            }
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(design),
               let font = NSFont(descriptor: descriptor, size: size) {
                return font
            }
            return base
        }
    }
}

enum TextLayout {
    static let inset: CGFloat = 2

    static func size(string: String, font: TextFont, fontSize: CGFloat, width: CGFloat) -> CGSize {
        let contentWidth = max(8, width - inset * 2)
        let sample = string.isEmpty ? " " : string
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(sample, font: font, fontSize: fontSize))
        var fit = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: sample.utf16.count),
            nil,
            CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            &fit
        )
        return CGSize(width: width, height: max(fontSize * 1.35, ceil(suggested.height) + inset * 2))
    }

    static func box(origin: CGPoint, width: CGFloat, string: String, font: TextFont, fontSize: CGFloat, limit: CGSize) -> CGRect {
        let fittedWidth = min(max(48, width), max(48, limit.width))
        let measured = size(string: string, font: font, fontSize: fontSize, width: fittedWidth)
        return clampBox(CGRect(origin: origin, size: CGSize(width: fittedWidth, height: measured.height)), in: limit)
    }

    static func attributed(_ string: String, font: TextFont, fontSize: CGFloat, color: NSColor = .white) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: string, attributes: [
            .font: font.nsFont(size: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, arrow, line, text, mosaic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .line: "Line"
        case .text: "Text"
        case .mosaic: "Mosaic"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
}

struct AnnotationStyle: Equatable {
    var color: AnnotColor = .default
    var lineWidth: CGFloat = 4
    var filled: Bool = false
    var mosaicStrength: CGFloat = 14
    var brushWidth: CGFloat = 28
    var fontSize: CGFloat = 32
    var font: TextFont = .sans
}

enum AnnotationGeometry: Equatable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case line(CGPoint, CGPoint)
    case arrow(CGPoint, CGPoint)
    case mosaic(points: [CGPoint], brush: CGFloat, strength: CGFloat)
    case text(rect: CGRect, string: String, fontSize: CGFloat, font: TextFont)

    var tool: AnnotationTool {
        switch self {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .mosaic: .mosaic
        case .text: .text
        }
    }

    var isMosaic: Bool {
        if case .mosaic = self { return true }
        return false
    }
}

struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var geometry: AnnotationGeometry
    var color: AnnotColor
    var lineWidth: CGFloat
    var filled: Bool

    var tool: AnnotationTool { geometry.tool }

    func bounds() -> CGRect {
        switch geometry {
        case let .rectangle(rect), let .ellipse(rect):
            return rect
        case let .line(a, b), let .arrow(a, b):
            let pad = lineWidth / 2 + 2
            return CGRect(
                x: min(a.x, b.x) - pad,
                y: min(a.y, b.y) - pad,
                width: abs(a.x - b.x) + pad * 2,
                height: abs(a.y - b.y) + pad * 2
            )
        case let .mosaic(points, brush, _):
            guard let first = points.first else { return .zero }
            var rect = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                rect = rect.union(CGRect(origin: point, size: .zero))
            }
            return rect.insetBy(dx: -brush / 2, dy: -brush / 2)
        case let .text(rect, _, _, _):
            return rect
        }
    }

    func translated(by delta: CGPoint, limit: CGSize) -> Annotation {
        var copy = self
        switch geometry {
        case let .rectangle(rect):
            copy.geometry = .rectangle(clampBox(rect.offsetBy(dx: delta.x, dy: delta.y), in: limit))
        case let .ellipse(rect):
            copy.geometry = .ellipse(clampBox(rect.offsetBy(dx: delta.x, dy: delta.y), in: limit))
        case let .line(a, b):
            let pair = clampSegment(a + delta, b + delta, in: limit)
            copy.geometry = .line(pair.0, pair.1)
        case let .arrow(a, b):
            let pair = clampSegment(a + delta, b + delta, in: limit)
            copy.geometry = .arrow(pair.0, pair.1)
        case let .mosaic(points, brush, strength):
            let moved = points.map { clamp($0 + delta, to: limit) }
            copy.geometry = .mosaic(points: moved, brush: brush, strength: strength)
        case let .text(rect, string, fontSize, font):
            copy.geometry = .text(
                rect: clampBox(rect.offsetBy(dx: delta.x, dy: delta.y), in: limit),
                string: string,
                fontSize: fontSize,
                font: font
            )
        }
        return copy
    }

    func resized(handle: BoxHandle, to point: CGPoint, limit: CGSize) -> Annotation {
        var copy = self
        let boundsLimit = CGRect(origin: .zero, size: limit)
        switch geometry {
        case let .rectangle(rect):
            var next = handle.resized(rect, to: point, yDown: true, minimum: 8)
            next = next.intersection(boundsLimit)
            if next.width >= 4, next.height >= 4 { copy.geometry = .rectangle(next) }
        case let .ellipse(rect):
            var next = handle.resized(rect, to: point, yDown: true, minimum: 8)
            next = next.intersection(boundsLimit)
            if next.width >= 4, next.height >= 4 { copy.geometry = .ellipse(next) }
        case let .mosaic(points, brush, strength):
            let old = bounds()
            var next = handle.resized(old, to: point, yDown: true, minimum: max(12, brush))
            next = next.intersection(boundsLimit.insetBy(dx: -brush, dy: -brush))
            guard old.width > 1, old.height > 1, next.width > 1, next.height > 1 else { return self }
            let sx = next.width / old.width
            let sy = next.height / old.height
            let mapped = points.map { point in
                CGPoint(
                    x: next.minX + (point.x - old.minX) * sx,
                    y: next.minY + (point.y - old.minY) * sy
                )
            }
            let scaledBrush = min(160, max(6, brush * (abs(sx) + abs(sy)) / 2))
            copy.geometry = .mosaic(points: mapped, brush: scaledBrush, strength: strength)
        case let .text(rect, string, fontSize, font):
            copy.geometry = resizeText(rect: rect, string: string, fontSize: fontSize, font: font, handle: handle, to: point, limit: limit)
        default:
            break
        }
        return copy
    }

    func withEndpoint(isStart: Bool, point: CGPoint, limit: CGSize) -> Annotation {
        var copy = self
        let clamped = clamp(point, to: limit)
        switch geometry {
        case let .line(a, b):
            copy.geometry = .line(isStart ? clamped : a, isStart ? b : clamped)
        case let .arrow(a, b):
            copy.geometry = .arrow(isStart ? clamped : a, isStart ? b : clamped)
        default:
            break
        }
        return copy
    }
}

private func resizeText(rect: CGRect, string: String, fontSize: CGFloat, font: TextFont, handle: BoxHandle, to point: CGPoint, limit: CGSize) -> AnnotationGeometry {
    switch handle {
    case .left, .right:
        let rawWidth = handle == .left ? rect.maxX - point.x : point.x - rect.minX
        let originX = handle == .left ? rect.maxX - max(48, rawWidth) : rect.minX
        let box = TextLayout.box(
            origin: CGPoint(x: originX, y: rect.minY),
            width: rawWidth,
            string: string,
            font: font,
            fontSize: fontSize,
            limit: limit
        )
        return .text(rect: box, string: string, fontSize: fontSize, font: font)
    default:
        let scale: CGFloat
        switch handle {
        case .topLeft, .bottomLeft:
            scale = (rect.maxX - point.x) / max(rect.width, 1)
        case .topRight, .bottomRight:
            scale = (point.x - rect.minX) / max(rect.width, 1)
        case .top:
            scale = (rect.maxY - point.y) / max(rect.height, 1)
        case .bottom:
            scale = (point.y - rect.minY) / max(rect.height, 1)
        default:
            scale = 1
        }
        let newSize = min(160, max(10, fontSize * max(0.2, scale)))
        let newWidth = max(48, rect.width * newSize / max(fontSize, 1))
        let measured = TextLayout.size(string: string, font: font, fontSize: newSize, width: newWidth)
        let origin: CGPoint
        switch handle {
        case .topLeft:
            origin = CGPoint(x: rect.maxX - newWidth, y: rect.maxY - measured.height)
        case .top, .topRight:
            origin = CGPoint(x: rect.minX, y: rect.maxY - measured.height)
        case .bottomLeft, .left:
            origin = CGPoint(x: rect.maxX - newWidth, y: rect.minY)
        default:
            origin = rect.origin
        }
        let box = clampBox(CGRect(x: origin.x, y: origin.y, width: newWidth, height: measured.height), in: limit)
        return .text(rect: box, string: string, fontSize: newSize, font: font)
    }
}

private func clampBox(_ rect: CGRect, in limit: CGSize) -> CGRect {
    var result = rect
    if result.width > limit.width { result.size.width = limit.width }
    if result.height > limit.height { result.size.height = limit.height }
    if result.minX < 0 { result.origin.x = 0 }
    if result.minY < 0 { result.origin.y = 0 }
    if result.maxX > limit.width { result.origin.x = limit.width - result.width }
    if result.maxY > limit.height { result.origin.y = limit.height - result.height }
    return result
}

private func clampSegment(_ a: CGPoint, _ b: CGPoint, in limit: CGSize) -> (CGPoint, CGPoint) {
    (clamp(a, to: limit), clamp(b, to: limit))
}

func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

enum AnnotationHit {
    case body(UUID)
    case box(UUID, BoxHandle)
    case endpoint(UUID, isStart: Bool)
}

func hitTestAnnotations(_ annotations: [Annotation], selectedID: UUID?, point: CGPoint, slop: CGFloat = 8) -> AnnotationHit? {
    if let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
        if let handleHit = hitHandles(selected, point: point, slop: slop) {
            return handleHit
        }
    }
    for annotation in annotations.reversed() {
        if hitBody(annotation, point: point, slop: slop) {
            return .body(annotation.id)
        }
    }
    return nil
}

private func hitHandles(_ annotation: Annotation, point: CGPoint, slop: CGFloat) -> AnnotationHit? {
    switch annotation.geometry {
    case let .line(a, b), let .arrow(a, b):
        if hypot(point.x - a.x, point.y - a.y) <= slop + 2 { return .endpoint(annotation.id, isStart: true) }
        if hypot(point.x - b.x, point.y - b.y) <= slop + 2 { return .endpoint(annotation.id, isStart: false) }
    case .rectangle, .ellipse, .mosaic, .text:
        let box = annotation.bounds()
        for handle in BoxHandle.hitOrder {
            let location = handle.point(in: box, yDown: true)
            if hypot(point.x - location.x, point.y - location.y) <= slop {
                return .box(annotation.id, handle)
            }
        }
    }
    return nil
}

private func hitBody(_ annotation: Annotation, point: CGPoint, slop: CGFloat) -> Bool {
    switch annotation.geometry {
    case let .rectangle(rect):
        let outer = rect.insetBy(dx: -slop, dy: -slop)
        if annotation.filled { return outer.contains(point) }
        let innerPad = annotation.lineWidth / 2 + slop
        let inner = rect.insetBy(dx: innerPad, dy: innerPad)
        if inner.width <= 0 || inner.height <= 0 { return outer.contains(point) }
        return outer.contains(point) && !inner.contains(point)
    case let .ellipse(rect):
        let outer = rect.insetBy(dx: -slop, dy: -slop)
        if annotation.filled { return ellipseContains(point, outer) }
        let inner = rect.insetBy(dx: annotation.lineWidth / 2 + slop, dy: annotation.lineWidth / 2 + slop)
        if inner.width <= 0 || inner.height <= 0 { return ellipseContains(point, outer) }
        return ellipseContains(point, outer) && !ellipseContains(point, inner)
    case let .line(a, b), let .arrow(a, b):
        return distance(point, toSegment: a, b) <= max(slop, annotation.lineWidth / 2 + 4)
    case let .mosaic(points, brush, _):
        guard let first = points.first else { return false }
        if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= brush / 2 + slop }
        for index in 1..<points.count {
            if distance(point, toSegment: points[index - 1], points[index]) <= brush / 2 + 4 {
                return true
            }
        }
        return false
    case let .text(rect, _, _, _):
        return rect.insetBy(dx: -slop, dy: -slop).contains(point)
    }
}

private func ellipseContains(_ point: CGPoint, _ rect: CGRect) -> Bool {
    let rx = rect.width / 2
    let ry = rect.height / 2
    if rx <= 0.5 || ry <= 0.5 { return false }
    let nx = (point.x - rect.midX) / rx
    let ny = (point.y - rect.midY) / ry
    return nx * nx + ny * ny <= 1
}

enum AnnotationRenderer {
    static func draw(_ annotation: Annotation, in context: CGContext, map: (CGPoint) -> CGPoint, lineScale: CGFloat) {
        if case let .text(rect, string, fontSize, font) = annotation.geometry {
            drawText(rect: rect, string: string, font: font, fontSize: fontSize, color: annotation.color, in: context, map: map, lineScale: lineScale)
            return
        }
        guard !annotation.geometry.isMosaic else { return }
        let path = mappedPath(for: annotation, map: map)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if annotation.filled, let fillPath = path {
            context.addPath(fillPath)
            context.setFillColor(annotation.color.cgColor.copy(alpha: 0.38) ?? annotation.color.cgColor)
            context.fillPath(using: .evenOdd)
        }
        if let path {
            stroke(path, color: annotation.color.cgColor, width: max(1, annotation.lineWidth * lineScale), halo: annotation.color.halo, in: context)
        }
        if case let .arrow(start, end) = annotation.geometry {
            drawArrowHead(from: map(start), to: map(end), width: max(1, annotation.lineWidth * lineScale), color: annotation.color, in: context)
        }
        context.restoreGState()
    }

    static func mosaicStrokePath(points: [CGPoint], brush: CGFloat, map: (CGPoint) -> CGPoint) -> CGPath {
        let center = CGMutablePath()
        guard let first = points.first else { return center }
        center.move(to: map(first))
        for point in points.dropFirst() {
            center.addLine(to: map(point))
        }
        return center.copy(strokingWithWidth: brush, lineCap: .round, lineJoin: .round, miterLimit: 2)
    }

    private static func drawText(rect: CGRect, string: String, font: TextFont, fontSize: CGFloat, color: AnnotColor, in context: CGContext, map: (CGPoint) -> CGPoint, lineScale: CGFloat) {
        guard !string.isEmpty else { return }
        let topLeft = map(CGPoint(x: rect.minX, y: rect.minY))
        let bottomRight = map(CGPoint(x: rect.maxX, y: rect.maxY))
        let dest = CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        ).insetBy(dx: TextLayout.inset * lineScale, dy: TextLayout.inset * lineScale)
        guard dest.width > 1, dest.height > 1 else { return }
        let scaled = max(1, fontSize * lineScale)
        let attributed = TextLayout.attributed(string, font: font, fontSize: scaled, color: NSColor(cgColor: color.cgColor) ?? .white)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: dest, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.setShadow(offset: .zero, blur: max(1.2, scaled * 0.14), color: color.halo)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

private func mappedPath(for annotation: Annotation, map: (CGPoint) -> CGPoint) -> CGPath? {
    switch annotation.geometry {
    case let .rectangle(rect), let .ellipse(rect):
        guard rect.width > 0.5, rect.height > 0.5 else { return nil }
        let local: CGPath = annotation.geometry.tool == .ellipse
            ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(rect: rect, transform: nil)
        return transform(local, map: map)
    case let .line(a, b), let .arrow(a, b):
        let path = CGMutablePath()
        let start = map(a)
        var finish = map(b)
        if case .arrow = annotation.geometry {
            let angle = atan2(finish.y - start.y, finish.x - start.x)
            let head = max(10, annotation.lineWidth * 3.2)
            finish = CGPoint(x: finish.x - cos(angle) * head * 0.72, y: finish.y - sin(angle) * head * 0.72)
        }
        path.move(to: start)
        path.addLine(to: finish)
        return path
    case .mosaic, .text:
        return nil
    }
}

private func transform(_ path: CGPath, map: (CGPoint) -> CGPoint) -> CGPath {
    let result = CGMutablePath()
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            result.move(to: map(points[0]))
        case .addLineToPoint:
            result.addLine(to: map(points[0]))
        case .addQuadCurveToPoint:
            result.addQuadCurve(to: map(points[1]), control: map(points[0]))
        case .addCurveToPoint:
            result.addCurve(to: map(points[2]), control1: map(points[0]), control2: map(points[1]))
        case .closeSubpath:
            result.closeSubpath()
        @unknown default:
            break
        }
    }
    return result
}

private func stroke(_ path: CGPath, color: CGColor, width: CGFloat, halo: CGColor, in context: CGContext) {
    context.setStrokeColor(halo)
    context.setLineWidth(width + 1.5)
    context.addPath(path)
    context.strokePath()
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.addPath(path)
    context.strokePath()
}

private func drawArrowHead(from start: CGPoint, to end: CGPoint, width: CGFloat, color: AnnotColor, in context: CGContext) {
    let angle = atan2(end.y - start.y, end.x - start.x)
    let length = max(12, width * 3.6)
    let spread: CGFloat = .pi / 7
    let left = CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread))
    let right = CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread))
    let path = CGMutablePath()
    path.move(to: end)
    path.addLine(to: left)
    path.addLine(to: right)
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(color.cgColor)
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(color.halo)
    context.setLineWidth(1)
    context.strokePath()
}
