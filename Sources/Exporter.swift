import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CapturedPiece {
    case still(CGImage)
    case gif(data: Data, frames: [CGImage], frameDelay: Double)
    case movie(URL, poster: CGImage?)

    var fileExtension: String {
        switch self {
        case .still: "png"
        case .gif: "gif"
        case .movie: "mp4"
        }
    }

    var contentType: UTType {
        switch self {
        case .still: .png
        case .gif: .gif
        case .movie: .mpeg4Movie
        }
    }

    var posterImage: CGImage? {
        switch self {
        case .still(let image): image
        case .gif(_, let frames, _): frames.first
        case .movie(_, let poster): poster
        }
    }
}

enum RecentLocations {
    private static let key = "recentSaveDirectories"

    static func load() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.prefix(3).compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    static func remember(_ directory: URL) {
        var paths = load().map(\.path)
        paths.removeAll { $0 == directory.path }
        paths.insert(directory.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(3)), forKey: key)
    }
}

enum Exporter {
    static func tempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sweepOldTemps() {
        let directory = tempDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func suggestedName(for piece: CapturedPiece, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return "Capture \(formatter.string(from: date)).\(piece.fileExtension)"
    }

    static func write(_ piece: CapturedPiece, to url: URL) throws {
        switch piece {
        case .still(let image):
            guard let data = pngData(image) else { throw CaptureError.writeFailed }
            try data.write(to: url, options: .atomic)
        case .gif(let data, _, _):
            try data.write(to: url, options: .atomic)
        case .movie(let source, _):
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: source, to: url)
        }
    }

    static func quickSave(_ piece: CapturedPiece, directory: URL) throws -> URL {
        let url = uniqueURL(directory: directory, name: suggestedName(for: piece))
        try write(piece, to: url)
        RecentLocations.remember(directory)
        return url
    }

    static func copyToPasteboard(_ piece: CapturedPiece) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch piece {
        case .still(let image):
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            pasteboard.writeObjects([nsImage])
            if let png = pngData(image) {
                pasteboard.setData(png, forType: .png)
            }
        case .gif(let data, _, _):
            let url = tempDirectory().appendingPathComponent(suggestedName(for: piece))
            try data.write(to: url, options: .atomic)
            pasteboard.writeObjects([url as NSURL])
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        case .movie(let url, _):
            pasteboard.writeObjects([url as NSURL])
            let type = NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier)
            if let data = try? Data(contentsOf: url), data.count < 80_000_000 {
                pasteboard.setData(data, forType: type)
            }
        }
    }

    static func encodeGIF(frames: [CGImage], delay: Double) -> Data? {
        guard !frames.isEmpty else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
            return nil
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
        ] as CFDictionary
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func presentSavePanel(for piece: CapturedPiece, level: NSWindow.Level = .modalPanel) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [piece.contentType]
        panel.nameFieldStringValue = suggestedName(for: piece)
        panel.title = "Save Capture"
        panel.prompt = "Save"
        panel.level = level
        if let recent = RecentLocations.load().first {
            panel.directoryURL = recent
        }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}

private func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

private func uniqueURL(directory: URL, name: String) -> URL {
    let nsName = name as NSString
    let base = nsName.deletingPathExtension
    let ext = nsName.pathExtension
    var candidate = directory.appendingPathComponent(name)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
        index += 1
    }
    return candidate
}
