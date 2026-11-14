import AppKit

// Translates Cocoa key events into the byte sequences a terminal expects,
// porting the relevant parts of PuTTY's format_arrow_key / format_function_key
// / format_small_keypad_key in terminal/terminal.c.
struct Keyboard {
    let term: TerminalEmulator
    let conf: Conf

    func bytes(for event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags
        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let cmd = flags.contains(.command)
        if cmd { return nil }   // leave Command shortcuts to the menu

        let key = event.keyCode

        // Arrow keys
        if let xkey = arrowXKey(key) {
            return arrowKey(xkey, shift: shift, ctrl: ctrl, alt: option)
        }

        // Function keys F1..F20
        if let n = functionNumber(key) {
            return functionKey(n, shift: shift, ctrl: ctrl, alt: option)
        }

        // Editing / navigation cluster
        if let seq = smallKeypad(key, shift: shift, ctrl: ctrl, alt: option) {
            return seq
        }

        guard let chars = event.charactersIgnoringModifiers, let first = chars.unicodeScalars.first
        else { return nil }

        // Return / Enter
        if key == 36 || key == 76 {
            return [0x0d]
        }
        if first == "\u{1b}" { return [0x1b] }   // Escape
        if key == 48 { return [0x09] }           // Tab

        // Backspace: honour "Backspace is Control-H / Control-?"
        if key == 51 { // delete (backspace)
            let isDelete = conf.getBool(K.bkspIsDelete)
            return [ isDelete ? 0x7f : 0x08 ]
        }
        if key == 117 { // forward delete
            return Array("\u{1b}[3~".utf8)
        }

        // Control combinations on letters and a few symbols.
        if ctrl {
            if let c = controlByte(for: chars) {
                return applyAlt([c], alt: option)
            }
        }

        // Ordinary text: send UTF-8.  Option acts as Meta by PuTTY's macOS
        // default (OSXOptionMeta = true): prefix with ESC and use the
        // unmodified character rather than an accented composition.
        let text = event.characters ?? chars
        if option {
            return [0x1b] + Array((event.charactersIgnoringModifiers ?? text).utf8)
        }
        return Array(text.utf8)
    }

    // MARK: arrow keys
    private func arrowXKey(_ keyCode: UInt16) -> UInt8? {
        switch keyCode {
        case 126: return UInt8(ascii: "A")   // up
        case 125: return UInt8(ascii: "B")   // down
        case 124: return UInt8(ascii: "C")   // right
        case 123: return UInt8(ascii: "D")   // left
        default: return nil
        }
    }

    private func shiftBitmap(_ shift: Bool, _ ctrl: Bool, _ alt: Bool) -> Int {
        var b = 1
        if shift { b += 1 }
        if alt { b += 2 }
        if ctrl { b += 4 }
        return b == 1 ? 0 : b
    }

    private func arrowKey(_ xkey: UInt8, shift: Bool, ctrl: Bool, alt: Bool) -> [UInt8] {
        var appFlg = term.appCursorKeys && !conf.getBool(K.noApplicC)
        var bitmap = 0
        switch ShArrowType(rawValue: conf.getInt(K.sharrowType)) ?? .application {
        case .application:
            if ctrl { appFlg.toggle() }
        case .bitmap:
            bitmap = shiftBitmap(shift, ctrl, alt)
        }
        if appFlg {
            return [0x1b, UInt8(ascii: "O"), xkey]
        } else if bitmap != 0 {
            return Array("\u{1b}[1;\(bitmap)".utf8) + [xkey]
        } else {
            return [0x1b, UInt8(ascii: "["), xkey]
        }
    }

    // MARK: function keys
    private func functionNumber(_ keyCode: UInt16) -> Int? {
        let map: [UInt16: Int] = [122:1, 120:2, 99:3, 118:4, 96:5, 97:6, 98:7,
                                  100:8, 101:9, 109:10, 103:11, 111:12,
                                  105:13, 107:14, 113:15, 106:16, 64:17,
                                  79:18, 80:19, 90:20]
        return map[keyCode]
    }

    private func functionKey(_ n: Int, shift: Bool, ctrl: Bool, alt: Bool) -> [UInt8] {
        let tildeCode = [-1, 11,12,13,14,15, 17,18,19,20,21, 23,24,25,26, 28,29, 31,32,33,34]
        var index = n
        var shift = shift
        let funky = FunkyType(rawValue: conf.getInt(K.funkyType)) ?? .tilde
        if funky != .xterm216 && funky != .sco {
            if shift && index <= 10 { shift = false; index += 10 }
        }
        guard index < tildeCode.count else { return [] }
        let code = tildeCode[index]
        switch funky {
        case .sco:
            let sco = Array("MNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz@[\\]^_`{".utf8)
            var i = (n >= 1 && n <= 12) ? n - 1 : 0
            if shift { i += 12 }
            if ctrl { i += 24 }
            return [0x1b, UInt8(ascii: "[")] + [sco[i]]
        case .vt100p where code >= 11 && code <= 24:
            var offt = 0
            if code > 15 { offt += 1 }
            if code > 21 { offt += 1 }
            return [0x1b, UInt8(ascii: "O"), UInt8(code + 0x50 - 11 - offt)]
        case .linux where code >= 11 && code <= 15:
            return [0x1b, UInt8(ascii: "["), UInt8(ascii: "["), UInt8(code + 0x41 - 11)]
        case .xterm, .xterm216:
            if code >= 11 && code <= 14 {
                var bitmap = 0
                if funky == .xterm216 { bitmap = shiftBitmap(shift, ctrl, alt) }
                if bitmap != 0 {
                    return Array("\u{1b}[1;\(bitmap)".utf8) + [UInt8(code + 0x50 - 11)]
                }
                return [0x1b, UInt8(ascii: "O"), UInt8(code + 0x50 - 11)]
            }
            fallthrough
        default:
            var bitmap = 0
            if funky == .xterm216 { bitmap = shiftBitmap(shift, ctrl, alt) }
            if bitmap != 0 { return Array("\u{1b}[\(code);\(bitmap)~".utf8) }
            return Array("\u{1b}[\(code)~".utf8)
        }
    }

    // MARK: editing cluster (Home/End/PgUp/PgDn/Ins/Del)
    private func smallKeypad(_ keyCode: UInt16, shift: Bool, ctrl: Bool, alt: Bool) -> [UInt8]? {
        let code: Int
        switch keyCode {
        case 115: code = 1   // Home
        case 114: code = 2   // Help/Insert
        case 119: code = 4   // End
        case 116: code = 5   // Page Up
        case 121: code = 6   // Page Down
        default: return nil
        }
        if (code == 1 || code == 4) && conf.getBool(K.rxvtHomeEnd) {
            return code == 1 ? Array("\u{1b}[H".utf8) : Array("\u{1b}Ow".utf8)
        }
        return Array("\u{1b}[\(code)~".utf8)
    }

    // MARK: control chars
    private func controlByte(for chars: String) -> UInt8? {
        guard let c = chars.unicodeScalars.first else { return nil }
        let v = c.value
        if v >= 0x40 && v < 0x80 {   // @A..Z[\]^_ -> 0x00..0x1f
            return UInt8(v & 0x1f)
        }
        if c == " " { return 0 }      // Ctrl+Space -> NUL
        switch c {
        case "2": return 0
        case "3": return 0x1b
        case "4": return 0x1c
        case "5": return 0x1d
        case "6": return 0x1e
        case "7": return 0x1f
        case "8": return 0x7f
        case "/": return 0x1f
        default: return nil
        }
    }

    private func applyAlt(_ bytes: [UInt8], alt: Bool) -> [UInt8] {
        alt ? [0x1b] + bytes : bytes
    }
}
