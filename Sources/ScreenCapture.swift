import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case noFrames
    case emptyRegion
    case writeFailed
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "That display isn't available for capture."
        case .noFrames: "Nothing was recorded."
        case .emptyRegion: "The capture region is too small."
        case .writeFailed: "The file couldn't be saved."
        case .message(let text): text
        }
    }
}

struct ListedWindow {
    var windowID: CGWindowID
    var frame: CGRect
    var owner: String
    var title: String
    var ownerPID: pid_t

    var label: String {
        if title.isEmpty || title == owner { return owner }
        return "\(owner) — \(title)"
    }
}

enum ScreenGrabber {
    static func listedWindows() -> [ListedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        let ignoredOwners: Set<String> = ["Window Server", "Dock", "SystemUIServer"]
        var windows: [ListedWindow] = []
        for dict in info {
            let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t ?? -1
            if ownerPID == pid { continue }
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }
            let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1
            if alpha < 0.05 { continue }
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            if ignoredOwners.contains(owner) || owner.isEmpty { continue }
            guard let bounds = dict[kCGWindowBounds as String] as? NSDictionary,
                  let displayRect = CGRect(dictionaryRepresentation: bounds) else { continue }
            if displayRect.width < 48 || displayRect.height < 48 { continue }
            let title = dict[kCGWindowName as String] as? String ?? ""
            let windowID = CGWindowID(dict[kCGWindowNumber as String] as? UInt32 ?? 0)
            windows.append(ListedWindow(
                windowID: windowID,
                frame: DisplaySpace.appKitRect(fromDisplay: displayRect),
                owner: owner,
                title: title,
                ownerPID: ownerPID
            ))
        }
        return windows
    }

    static func captureStill(appKitRect: CGRect, screen: NSScreen, showsCursor: Bool) async throws -> CGImage {
        let filter = try await contentFilter(for: screen)
        let source = sanitizedSource(appKitRect, on: screen)
        guard source.width >= 2, source.height >= 2 else { throw CaptureError.emptyRegion }
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(2, Int((source.width * scale).rounded()))
        config.height = max(2, Int((source.height * scale).rounded()))
        config.showsCursor = showsCursor
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func contentFilter(for screen: NSScreen) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        let excluded = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        filter.includeMenuBar = true
        return filter
    }

    static func sanitizedSource(_ appKitRect: CGRect, on screen: NSScreen) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        let source = DisplaySpace.sourceRect(forAppKitRect: appKitRect, on: screen).intersection(bounds)
        let integral = CGRect(
            x: source.minX.rounded(.down),
            y: source.minY.rounded(.down),
            width: source.width.rounded(.down),
            height: source.height.rounded(.down)
        )
        return integral
    }
}

func permissionDenied(_ error: Error) -> Bool {
    let text = error.localizedDescription.lowercased()
    return text.contains("permission") || text.contains("declined") || text.contains("tcc") || text.contains("not authorized")
}
