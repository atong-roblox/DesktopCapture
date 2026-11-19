import AppKit
import SwiftUI

private let appDelegate = AppDelegate()

@main
enum CaptureMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let session = CaptureSession()
    private let hotkey = HotkeyManager()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            let passed = runSelfTest()
            exit(passed ? 0 : 1)
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "local.capture.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        Exporter.sweepOldTemps()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Capture")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotkey.onPress = { [weak self] in
            self?.session.begin()
        }
        session.hotkeyAvailable = hotkey.register(HotkeyShortcut.current)
        SettingsWindow.shared.model.onApplyShortcut = { [weak self] shortcut in
            self?.applyShortcut(shortcut) ?? false
        }
        SettingsWindow.shared.model.onListeningChanged = { [weak self] listening in
            guard let self else { return }
            if listening {
                self.hotkey.unregister()
                self.session.hotkeyAvailable = false
            } else {
                self.session.hotkeyAvailable = self.hotkey.register(HotkeyShortcut.current)
            }
        }

        if CommandLine.arguments.contains("--preview") {
            session.begin(force: true)
        } else if !CGPreflightScreenCaptureAccess() {
            PermissionWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {}

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = HotkeyShortcut.current
        let take = menu.addItem(withTitle: "Take Screenshot", action: #selector(takeScreenshot), keyEquivalent: "")
        take.target = self
        if let equivalent = shortcut.menuKeyEquivalent {
            take.keyEquivalent = equivalent.0
            take.keyEquivalentModifierMask = equivalent.1
        } else {
            take.title = "Take Screenshot (\(shortcut.displayString))"
        }
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        if LoginItem.needsApproval {
            let allow = menu.addItem(withTitle: "Allow in Login Items…", action: #selector(openLoginItems), keyEquivalent: "")
            allow.target = self
        }
        menu.addItem(.separator())
        let allowed = CGPreflightScreenCaptureAccess()
        if allowed {
            let item = menu.addItem(withTitle: "Screen Recording Allowed", action: nil, keyEquivalent: "")
            item.isEnabled = false
        } else {
            let item = menu.addItem(withTitle: "Grant Screen Recording…", action: #selector(grantAccess), keyEquivalent: "")
            item.target = self
        }
        if !session.hotkeyAvailable {
            let item = menu.addItem(withTitle: "Shortcut Unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
    }

    @objc private func takeScreenshot() {
        session.begin()
    }

    @objc private func showSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        SettingsWindow.shared.model.refreshLogin()
        if LoginItem.needsApproval {
            LoginItem.openSettings()
        }
    }

    @objc private func openLoginItems() {
        LoginItem.openSettings()
    }

    @objc private func grantAccess() {
        PermissionWindow.show()
    }

    private func applyShortcut(_ shortcut: HotkeyShortcut) -> Bool {
        let previous = HotkeyShortcut.current
        HotkeyShortcut.current = shortcut
        let registered = hotkey.register(shortcut)
        session.hotkeyAvailable = registered
        if !registered {
            HotkeyShortcut.current = previous
        }
        return registered
    }
}

final class PermissionWindow: NSObject {
    static let shared = PermissionWindow()
    private var window: NSWindow?
    private var timer: Timer?

    static func show() {
        shared.present()
    }

    private func present() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Capture"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PermissionView(
            grant: { [weak self] in self?.grant() },
            quit: { NSApp.terminate(nil) }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if CGPreflightScreenCaptureAccess() {
                self?.close()
            }
        }
    }

    private func grant() {
        if CGRequestScreenCaptureAccess() {
            close()
            return
        }
        if let url = URL(string: "x-apple.systemsettings:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
    }
}

struct PermissionView: View {
    var grant: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screen Recording")
                .font(.system(size: 20, weight: .semibold))
            Text("Capture needs Screen Recording access to take screenshots and recordings. Press \(HotkeyShortcut.current.displayString) when you’re ready. You can change that shortcut in Settings.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Everything stays on this Mac. Images are only copied to the clipboard or saved to a folder you choose. Nothing is uploaded.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Quit", action: quit)
                Spacer()
                Button("Grant Access", action: grant)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
