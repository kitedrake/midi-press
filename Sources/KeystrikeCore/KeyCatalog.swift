import Carbon.HIToolbox
import Foundation

/// The keys Keystrike can press: hardware key codes, how to show them, and the flags a real keyboard adds to them.
///
/// Letter, number and punctuation keys are named with the current keyboard layout (on a German layout the key
/// left of T shows "Z"), so a shortcut reads the way it's printed on the user's keyboard.
public enum KeyCatalog {
    public enum Group: String, CaseIterable, Sendable {
        case characters = "Letters, Numbers & Symbols"
        case special = "Return, Tab, Space & Delete"
        case navigation = "Arrows & Navigation"
        case function = "Function Keys"
        case keypad = "Keypad"
    }

    public struct Key: Hashable, Sendable {
        public var code: UInt16
        /// Fixed name; nil for keys named from the keyboard layout.
        public var fixedName: String?
        public var group: Group
    }

    /// The modifier keys themselves, pressed around a shortcut's key.
    public static let modifierKeyCodes: [(Modifiers, UInt16)] = [
        (.control, UInt16(kVK_Control)), (.option, UInt16(kVK_Option)), (.shift, UInt16(kVK_Shift)), (.command, UInt16(kVK_Command)),
    ]

    /// Key codes of the modifier keys (left and right), caps lock and fn: never a shortcut's key.
    public static let modifierOnlyCodes: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_RightCommand), UInt16(kVK_Shift), UInt16(kVK_RightShift), UInt16(kVK_Option),
        UInt16(kVK_RightOption), UInt16(kVK_Control), UInt16(kVK_RightControl), UInt16(kVK_CapsLock), UInt16(kVK_Function),
    ]

    public static let keys: [Key] = {
        var keys: [Key] = []
        // Layout-named keys, in keyboard order (top row first).
        let characters = [
            kVK_ANSI_Grave, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
            kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_Minus, kVK_ANSI_Equal,
            kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T, kVK_ANSI_Y, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O,
            kVK_ANSI_P, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash,
            kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
            kVK_ANSI_Semicolon, kVK_ANSI_Quote,
            kVK_ISO_Section, kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_N, kVK_ANSI_M, kVK_ANSI_Comma,
            kVK_ANSI_Period, kVK_ANSI_Slash,
        ]
        keys += characters.map { Key(code: UInt16($0), fixedName: nil, group: .characters) }
        let special: [(Int, String)] = [
            (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Space, "Space"), (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"),
            (kVK_Escape, "⎋"), (kVK_Help, "Help"),
        ]
        keys += special.map { Key(code: UInt16($0.0), fixedName: $0.1, group: .special) }
        let navigation: [(Int, String)] = [
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"), (kVK_Home, "↖"),
            (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"),
        ]
        keys += navigation.map { Key(code: UInt16($0.0), fixedName: $0.1, group: .navigation) }
        let function: [Int] = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13,
            kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        keys += function.enumerated().map { Key(code: UInt16($0.element), fixedName: "F\($0.offset + 1)", group: .function) }
        let keypad: [(Int, String)] = [
            (kVK_ANSI_Keypad0, "Keypad 0"), (kVK_ANSI_Keypad1, "Keypad 1"), (kVK_ANSI_Keypad2, "Keypad 2"),
            (kVK_ANSI_Keypad3, "Keypad 3"), (kVK_ANSI_Keypad4, "Keypad 4"), (kVK_ANSI_Keypad5, "Keypad 5"),
            (kVK_ANSI_Keypad6, "Keypad 6"), (kVK_ANSI_Keypad7, "Keypad 7"), (kVK_ANSI_Keypad8, "Keypad 8"),
            (kVK_ANSI_Keypad9, "Keypad 9"), (kVK_ANSI_KeypadDecimal, "Keypad ."), (kVK_ANSI_KeypadPlus, "Keypad +"),
            (kVK_ANSI_KeypadMinus, "Keypad −"), (kVK_ANSI_KeypadMultiply, "Keypad ×"), (kVK_ANSI_KeypadDivide, "Keypad ÷"),
            (kVK_ANSI_KeypadEquals, "Keypad ="), (kVK_ANSI_KeypadEnter, "⌤"), (kVK_ANSI_KeypadClear, "Clear"),
        ]
        keys += keypad.map { Key(code: UInt16($0.0), fixedName: $0.1, group: .keypad) }
        return keys
    }()

    static let byCode: [UInt16: Key] = Dictionary(keys.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })

    /// Names that are a single symbol (no space is put between them and the modifier symbols).
    public static func isSymbol(_ name: String) -> Bool { name.count == 1 }

    /// A spoken name for symbol keys, for menus and accessibility ("Return" for ↩).
    public static func longName(for code: UInt16) -> String {
        switch Int(code) {
        case kVK_Return: "Return ↩"
        case kVK_Tab: "Tab ⇥"
        case kVK_Delete: "Delete ⌫"
        case kVK_ForwardDelete: "Forward Delete ⌦"
        case kVK_Escape: "Escape ⎋"
        case kVK_LeftArrow: "Left Arrow ←"
        case kVK_RightArrow: "Right Arrow →"
        case kVK_UpArrow: "Up Arrow ↑"
        case kVK_DownArrow: "Down Arrow ↓"
        case kVK_Home: "Home ↖"
        case kVK_End: "End ↘"
        case kVK_PageUp: "Page Up ⇞"
        case kVK_PageDown: "Page Down ⇟"
        case kVK_ANSI_KeypadEnter: "Keypad Enter ⌤"
        case kVK_ANSI_KeypadClear: "Keypad Clear"
        default: name(for: code)
        }
    }

    /// The key's label: a fixed name, or the character the current keyboard layout types with it.
    public static func name(for code: UInt16) -> String {
        if let fixed = byCode[code]?.fixedName { return fixed }
        if let character = layoutCharacter(for: code) { return character }
        return "Key \(code)"
    }

    /// The flags a real keyboard puts on the key's events: arrows count as keypad and fn keys, F-keys and the
    /// navigation block as fn keys, keypad keys as keypad. Some apps look at these.
    public static func intrinsicFlags(for code: UInt16) -> CGEventFlags {
        switch Int(code) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            return [.maskNumericPad, .maskSecondaryFn]
        case kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help:
            return .maskSecondaryFn
        default:
            if byCode[code]?.group == .function { return .maskSecondaryFn }
            if byCode[code]?.group == .keypad { return .maskNumericPad }
            return []
        }
    }

    public static func cgFlags(_ modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    // MARK: Keyboard layout

    private static let layoutLock = NSLock()
    nonisolated(unsafe) private static var layoutCache: (id: String, names: [UInt16: String])?

    /// The (uppercased) character the current layout types for a key with no modifiers, or nil. The Text Input
    /// Sources API must be used on the main thread; elsewhere the names last read there are used.
    static func layoutCharacter(for code: UInt16) -> String? {
        guard Thread.isMainThread else {
            layoutLock.lock()
            defer { layoutLock.unlock() }
            return layoutCache?.names[code]
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let id = (TISGetInputSourceProperty(source, kTISPropertyInputSourceID)).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        } ?? ""
        layoutLock.lock()
        defer { layoutLock.unlock() }
        if let cache = layoutCache, cache.id == id { return cache.names[code] }
        var names: [UInt16: String] = [:]
        if let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
            layoutData.withUnsafeBytes { raw in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                for key in keys where key.fixedName == nil {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, key.code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { names[key.code] = text.uppercased() }
                }
            }
        }
        layoutCache = (id, names)
        return names[code]
    }
}
