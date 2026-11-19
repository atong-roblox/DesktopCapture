import AppKit
import AVFoundation
import AVKit
import SwiftUI

final class PinBoard {
    static let shared = PinBoard()
    private var pins: [PinController] = []

    func present(_ piece: CapturedPiece, mode: PreviewMode = .pin) {
        let controller = PinController(piece: piece, mode: mode)
        pins.append(controller)
        let index = pins.count - 1
        controller.onClose = { [weak self, weak controller] in
            self?.pins.removeAll { $0 === controller }
        }
        controller.show(cascade: index)
    }
}

enum PreviewMode {
    case pin
    case scroll

    var title: String {
        switch self {
        case .pin: "Pinned"
        case .scroll: "Scrolled Capture"
        }
    }
}

final class PinController: NSWindowController, NSWindowDelegate {
    let piece: CapturedPiece
    let mode: PreviewMode
    var didCopy = false
    var onClose: (() -> Void)?
    private var didClose = false

    init(piece: CapturedPiece, mode: PreviewMode) {
        self.piece = piece
        self.mode = mode
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = mode.title
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = PreviewPalette.background
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: PinView(
            piece: piece,
            mode: mode,
            onSave: { [weak self] in self?.save() },
            onCopy: { [weak self] in self?.copy() },
            onDiscard: { [weak self] in self?.window?.close() },
            onHover: { [weak self] hovering in self?.setWindowButtonsVisible(hovering) }
        ))
    }

    private func setWindowButtonsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func show(cascade: Int) {
        guard let window else { return }
        let screen = screenContaining(point: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        let size = fittedSize(on: screen)
        let origin = CGPoint(
            x: screen.visibleFrame.midX - size.width / 2 + CGFloat(cascade) * 28,
            y: screen.visibleFrame.midY - size.height / 2 - CGFloat(cascade) * 28
        )
        window.setFrame(CGRect(origin: origin, size: size), display: true)
        window.minSize = NSSize(width: 280, height: 180)
        if mode == .pin {
            window.contentAspectRatio = size
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        if !didCopy, case let .movie(url, _) = piece {
            try? FileManager.default.removeItem(at: url)
        }
        onClose?()
    }

    private func save() {
        guard let window else { return }
        guard let url = Exporter.presentSavePanel(for: piece, level: .floating) else { return }
        do {
            try Exporter.write(piece, to: url)
            RecentLocations.remember(url.deletingLastPathComponent())
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window)
        }
    }

    private func copy() {
        do {
            try Exporter.copyToPasteboard(piece)
            if case .movie = piece { didCopy = true }
        } catch {
            guard let window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    private func fittedSize(on screen: NSScreen) -> NSSize {
        let image = piece.posterImage
        let scale = screen.backingScaleFactor
        var width = CGFloat(image?.width ?? 1280) / scale
        var height = CGFloat(image?.height ?? 720) / scale
        if case .movie = piece, image == nil {
            width = 720
            height = 405
        }
        let maxWidth = screen.visibleFrame.width * 0.62
        let maxHeight = screen.visibleFrame.height * 0.68
        let aspect = max(width / max(height, 1), 0.2)
        if width > maxWidth {
            width = maxWidth
            height = width / aspect
        }
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        width = max(280, width)
        height = max(180, height)
        return NSSize(width: width, height: height)
    }
}

enum PreviewPalette {
    static let background = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1)
}

struct PinView: View {
    let piece: CapturedPiece
    let mode: PreviewMode
    var onSave: () -> Void
    var onCopy: () -> Void
    var onDiscard: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    @State private var hovering = true

    var body: some View {
        ZStack {
            Color.black
            preview
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
                .allowsHitTesting(false)
                .opacity(hovering ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            toolbar
                .padding(.bottom, toolbarBottomInset)
                .opacity(hovering ? 1 : 0)
                .offset(y: hovering ? 0 : 6)
                .allowsHitTesting(hovering)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) { hovering = inside }
            onHover(inside)
        }
    }

    private var toolbarBottomInset: CGFloat {
        if case .movie = piece { return 64 }
        return 12
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            if let image = piece.posterImage {
                Text("\(image.width) × \(image.height)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .lineLimit(1)
                    .fixedSize()
            }
            toolbarButton("Discard", symbol: "trash", shortcut: .cancelAction, action: onDiscard)
            toolbarButton("Copy", symbol: "doc.on.doc", shortcut: nil, action: onCopy)
            toolbarButton("Save", symbol: "square.and.arrow.down", shortcut: .defaultAction, action: onSave)
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private func toolbarButton(_ title: String, symbol: String, shortcut: KeyboardShortcut?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(PinToolbarButtonStyle())
        .keyboardShortcut(shortcut)
        .help(title)
    }

    @ViewBuilder
    private var preview: some View {
        switch piece {
        case .still(let image):
            imageView(image)
        case let .gif(_, frames, delay):
            GIFFramesView(frames: frames, delay: delay)
        case let .movie(url, _):
            MoviePlayer(url: url)
        }
    }

    private func imageView(_ image: CGImage) -> some View {
        Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

private struct PinToolbarButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle().fill(Color.white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0))
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct GIFFramesView: View {
    let frames: [CGImage]
    let delay: Double
    @State private var index = 0

    var body: some View {
        let frame = frames[min(index, frames.count - 1)]
        Image(nsImage: NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height)))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .onReceive(Timer.publish(every: max(delay, 0.05), on: .main, in: .common).autoconnect()) { _ in
                guard frames.count > 1 else { return }
                index = (index + 1) % frames.count
            }
    }
}

struct MoviePlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        context.coordinator.loop(item: item, player: player)
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var observer: NSObjectProtocol?

        func loop(item: AVPlayerItem, player: AVPlayer) {
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
        }
    }
}
