import AppKit
import ServiceManagement
import SwiftUI

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systemsettings:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var shortcut = HotkeyShortcut.current
    @Published var listening = false
    @Published var loginEnabled = LoginItem.isEnabled
    @Published var message: String?

    var onApplyShortcut: ((HotkeyShortcut) -> Bool)?
    var onListeningChanged: ((Bool) -> Void)?

    func refreshLogin() {
        loginEnabled = LoginItem.isEnabled
        if !listening, LoginItem.needsApproval {
            message = "macOS still needs you to allow Capture in Login Items."
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginEnabled = LoginItem.isEnabled
            if LoginItem.needsApproval {
                message = "Allow Capture in System Settings → General → Login Items."
            } else if enabled && !loginEnabled {
                message = "Capture isn’t set to open at login yet."
            } else {
                message = nil
            }
        } catch {
            loginEnabled = LoginItem.isEnabled
            message = error.localizedDescription
        }
    }

    func beginListening() {
        listening = true
        message = "Press a shortcut that includes ⌘, ⌥, or ⌃. Esc cancels."
        onListeningChanged?(true)
    }

    func cancelListening() {
        listening = false
        message = nil
        onListeningChanged?(false)
    }

    func capture(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            cancelListening()
            return true
        }
        if HotkeyShortcut.isModifier(keyCode: event.keyCode) {
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasPrimary = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        guard hasPrimary else {
            message = "Include ⌘, ⌥, or ⌃ so the shortcut doesn’t fire while typing."
            return true
        }
        let next = HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: HotkeyShortcut.carbonModifiers(from: flags))
        guard onApplyShortcut?(next) == true else {
            message = "That shortcut couldn’t be registered. Try another."
            return true
        }
        shortcut = next
        listening = false
        message = nil
        return true
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    let model = SettingsModel()
    private var window: NSWindow?
    private var monitor: Any?

    func show() {
        model.refreshLogin()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Capture Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func startListening() {
        stopMonitor()
        model.beginListening()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.listening else { return event }
            return self.model.capture(event) ? nil : event
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshLogin()
    }

    func windowWillClose(_ notification: Notification) {
        if model.listening {
            model.cancelListening()
        }
        stopMonitor()
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Shortcut")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) {
                Button(model.listening ? "Press shortcut…" : model.shortcut.displayString) {
                    SettingsWindow.shared.startListening()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 14, weight: .semibold).monospaced())
                if model.listening {
                    Button("Cancel") {
                        model.cancelListening()
                    }
                }
            }
            Text("Click the shortcut, then press the keys you want. It needs ⌘, ⌥, or ⌃.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Open at login", isOn: Binding(
                get: { model.loginEnabled },
                set: { model.setLogin($0) }
            ))
            if LoginItem.needsApproval || model.message != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let message = model.message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if LoginItem.needsApproval {
                        Button("Open Login Items") {
                            LoginItem.openSettings()
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
    }
}
