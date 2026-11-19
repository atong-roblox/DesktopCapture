import SwiftUI

struct TopBar: View {
    @ObservedObject var session: CaptureSession

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(CaptureTarget.allCases) { item in
                        barButton(title: item.title, symbol: item.symbol, selected: session.target == item) {
                            session.setTarget(item)
                        }
                        .disabled(!session.controlsEnabled)
                    }
                }
                hairline
                HStack(spacing: 2) {
                    ForEach(CaptureKind.allCases) { item in
                        barButton(title: item.title, symbol: item.symbol, selected: session.kind == item) {
                            session.setKind(item)
                        }
                        .disabled(!session.controlsEnabled)
                    }
                }
                hairline
                barButton(title: "Cancel", symbol: "xmark", selected: false, action: session.cancel)
            }
            .padding(6)
            .modifier(ChromeBackground(radius: 16))

            Text(session.statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .modifier(ChromeBackground(radius: 999))
        }
        .fixedSize()
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 18)
    }
}

struct AnnotationBar: View {
    @ObservedObject var session: CaptureSession

    var body: some View {
        HStack(spacing: 8) {
            if session.showsDrawingTools {
                HStack(spacing: 2) {
                    ForEach(AnnotationTool.allCases) { tool in
                        barButton(
                            title: "",
                            symbol: tool.symbol,
                            selected: session.tool == tool,
                            help: tool.title
                        ) {
                            session.setTool(tool)
                        }
                    }
                }
                if session.optionTool != .select {
                    hairline
                    options
                }
            }
            if session.showsFinishControl {
                if session.showsDrawingTools { hairline }
                primary
            }
        }
        .padding(6)
        .modifier(ChromeBackground(radius: 16))
        .fixedSize()
    }

    @ViewBuilder
    private var options: some View {
        if session.optionTool == .mosaic {
            labeledSlider("Block", value: session.style.mosaicStrength, range: 6...40) {
                session.setMosaicStrength($0)
            }
            labeledSlider("Brush", value: session.style.brushWidth, range: 8...72) {
                session.setBrushWidth($0)
            }
        } else if session.optionTool == .text {
            colorDots
            labeledSlider("Size", value: session.style.fontSize, range: 12...96) {
                session.setFontSize($0)
            }
            HStack(spacing: 2) {
                ForEach(TextFont.allCases) { font in
                    barButton(title: font.title, symbol: nil, selected: session.style.font == font) {
                        session.setTextFont(font)
                    }
                }
            }
        } else {
            colorDots
            labeledSlider("Stroke", value: session.style.lineWidth, range: 1...16) {
                session.setLineWidth($0)
            }
            if session.optionTool == .rectangle || session.optionTool == .ellipse {
                barButton(
                    title: "Fill",
                    symbol: session.style.filled ? "square.fill" : "square",
                    selected: session.style.filled
                ) {
                    session.setFilled(!session.style.filled)
                }
            }
        }
    }

    private var colorDots: some View {
        HStack(spacing: 2) {
            ForEach(AnnotColor.presets) { color in
                let chosen = session.style.color == color
                Button {
                    session.setColor(color)
                } label: {
                    Circle()
                        .fill(Color(cgColor: color.cgColor))
                        .frame(width: 14, height: 14)
                        .frame(width: 28, height: 28)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(chosen ? 0.2 : 0.07))
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(chosen ? 0.95 : 0), lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(color.name)
            }
        }
    }

    @ViewBuilder
    private var primary: some View {
        if session.phase == .recording {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 1, green: 0.27, blue: 0.23))
                    .frame(width: 8, height: 8)
                Text(formatDuration(session.recordingTime))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                barButton(title: "Stop", symbol: "stop.fill", selected: false, prominent: .stop) {
                    session.toggleRecord()
                }
            }
        } else if session.kind == .image {
            barButton(title: "Done", symbol: "checkmark", selected: false, prominent: .done, action: session.done)
        } else {
            barButton(title: "Record", symbol: "record.circle", selected: false, prominent: .record) {
                session.toggleRecord()
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 18)
    }

    private func labeledSlider(_ title: String, value: CGFloat, range: ClosedRange<CGFloat>, set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
                .frame(width: 72)
                .tint(.white)
            Text("\(Int(value.rounded()))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, alignment: .trailing)
        }
    }
}

struct ActionRail: View {
    @ObservedObject var session: CaptureSession

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 4) {
                if session.showsAutoScroll {
                    barButton(title: "", symbol: "scroll", selected: false, help: "Auto Scroll", action: session.startAutoScroll)
                    Rectangle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 18, height: 1)
                }
                barButton(title: "", symbol: "square.and.arrow.down", selected: session.isSaveMenuOpen, help: "Save", action: session.toggleSaveMenu)
                barButton(title: "", symbol: "doc.on.clipboard", selected: false, help: "Copy", action: session.copy)
                barButton(title: "", symbol: "pin", selected: false, help: "Pin", action: session.pin)
            }
            if session.isSaveMenuOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.recentLocations, id: \.path) { url in
                        Button {
                            session.saveToRecent(url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .frame(width: 16)
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                            }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                    }
                    Button(action: session.chooseSaveLocation) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .frame(width: 16)
                            Text("Choose Location…")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Choose Location…")
                }
                .padding(4)
                .frame(maxWidth: 180, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(6)
        .modifier(ChromeBackground(radius: 16))
        .fixedSize()
    }
}

enum ProminentStyle {
    case none, done, record, stop
}

func barButton(
    title: String,
    symbol: String?,
    selected: Bool,
    prominent: ProminentStyle = .none,
    help: String? = nil,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
            }
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: title == "GIF" ? 12 : 13, weight: title == "GIF" ? .bold : .medium))
            }
        }
    }
    .buttonStyle(ChromeButtonStyle(selected: selected, prominent: prominent, iconOnly: title.isEmpty))
    .helpText(help ?? (title.isEmpty ? nil : title))
}

struct ChromeButtonStyle: PrimitiveButtonStyle {
    var selected: Bool
    var prominent: ProminentStyle
    var iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, selected: selected, prominent: prominent, iconOnly: iconOnly)
    }
}

private struct ChromeButtonBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    var selected: Bool
    var prominent: ProminentStyle
    var iconOnly: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .padding(.horizontal, iconOnly ? 8 : 12)
            .padding(.vertical, 7)
            .frame(minWidth: iconOnly ? 36 : 0, minHeight: 32)
            .foregroundStyle(foreground(selected: selected, prominent: prominent))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(cellFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
            .gesture(TapGesture().onEnded {
                guard isEnabled else { return }
                configuration.trigger()
            })
    }

    private var cellFill: Color {
        if prominent != .none { return fill(selected: selected, prominent: prominent) }
        if selected { return Color.white.opacity(0.22) }
        if hovered { return Color.white.opacity(0.16) }
        return Color.white.opacity(0.08)
    }
}

extension View {
    @ViewBuilder func helpText(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}

private func fill(selected: Bool, prominent: ProminentStyle) -> Color {
    switch prominent {
    case .done: return Color.white
    case .record: return Color(red: 1, green: 0.27, blue: 0.23)
    case .stop: return Color.white.opacity(0.16)
    case .none: return Color.white.opacity(selected ? 0.18 : 0)
    }
}

private func foreground(selected: Bool, prominent: ProminentStyle) -> Color {
    switch prominent {
    case .done: return .black
    case .record, .stop: return .white
    case .none: return .white.opacity(selected ? 1 : 0.82)
    }
}

struct ChromeBackground: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.32), radius: 16, y: 8)
            .environment(\.colorScheme, .dark)
    }
}
