import AppKit
import Carbon.HIToolbox
import Foundation

struct HotkeyShortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    static var current: HotkeyShortcut {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: codeKey) != nil else { return .default }
            return HotkeyShortcut(
                keyCode: UInt32(defaults.integer(forKey: codeKey)),
                modifiers: UInt32(defaults.integer(forKey: modifiersKey))
            )
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Int(newValue.keyCode), forKey: codeKey)
            defaults.set(Int(newValue.modifiers), forKey: modifiersKey)
        }
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.displayLabels[keyCode] ?? "Key \(keyCode)")
        return parts.joined()
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// A menu key equivalent AppKit can draw. Nil for keys the menu cannot show.
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        guard let glyph = Self.menuGlyphs[keyCode] else { return nil }
        return (glyph, modifierFlags)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    static func isModifier(keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_Shift, kVK_Option, kVK_Control, kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl, kVK_Function, kVK_CapsLock:
            return true
        default:
            return false
        }
    }

    private static let codeKey = "captureHotkeyCode"
    private static let modifiersKey = "captureHotkeyModifiers"

    private static let displayLabels: [UInt32: String] = {
        var labels: [UInt32: String] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Equal, "="), (kVK_ANSI_Minus, "-"), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Period, "."), (kVK_ANSI_Grave, "`"),
            (kVK_Space, "Space"), (kVK_Return, "Return"), (kVK_Tab, "Tab"),
            (kVK_Delete, "Delete"), (kVK_Escape, "Esc"), (kVK_ForwardDelete, "Fwd Del"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12")
        ]
        for (code, label) in letters {
            labels[UInt32(code)] = label
        }
        return labels
    }()

    private static let menuGlyphs: [UInt32: String] = {
        var glyphs: [UInt32: String] = [:]
        for (code, label) in displayLabels {
            if label.count == 1, let scalar = label.unicodeScalars.first, scalar.isASCII {
                glyphs[code] = label.lowercased()
            }
        }
        glyphs[UInt32(kVK_Space)] = " "
        func functionGlyph(_ key: Int) -> String {
            String(UnicodeScalar(key)!)
        }
        let functions: [(Int, Int)] = [
            (kVK_F1, NSF1FunctionKey), (kVK_F2, NSF2FunctionKey), (kVK_F3, NSF3FunctionKey),
            (kVK_F4, NSF4FunctionKey), (kVK_F5, NSF5FunctionKey), (kVK_F6, NSF6FunctionKey),
            (kVK_F7, NSF7FunctionKey), (kVK_F8, NSF8FunctionKey), (kVK_F9, NSF9FunctionKey),
            (kVK_F10, NSF10FunctionKey), (kVK_F11, NSF11FunctionKey), (kVK_F12, NSF12FunctionKey),
            (kVK_LeftArrow, NSLeftArrowFunctionKey), (kVK_RightArrow, NSRightArrowFunctionKey),
            (kVK_UpArrow, NSUpArrowFunctionKey), (kVK_DownArrow, NSDownArrowFunctionKey)
        ]
        for (code, glyph) in functions {
            glyphs[UInt32(code)] = functionGlyph(glyph)
        }
        return glyphs
    }()
}

final class HotkeyManager {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    @discardableResult
    func register(_ shortcut: HotkeyShortcut = .current) -> Bool {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            let installed = InstallEventHandler(
                GetApplicationEventTarget(),
                hotkeyEventHandler,
                1,
                &spec,
                pointer,
                &handler
            )
            guard installed == noErr else { return false }
        }
        unregisterHotKey()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4341_5054), id: 1)
        let registered = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        return registered == noErr
    }

    func unregister() {
        unregisterHotKey()
    }

    func handle() {
        onPress?()
    }

    private func unregisterHotKey() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }
}

private func hotkeyEventHandler(_ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.handle()
    }
    return noErr
}
