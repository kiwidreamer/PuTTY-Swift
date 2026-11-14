import Foundation

// A pragmatic xterm/VT100-compatible terminal emulator, in the spirit of
// PuTTY's terminal/terminal.c but written from scratch for this port.
// It owns the character grid, scrollback and the escape-sequence parser.

enum TermColor: Equatable {
    case defaultColor
    case indexed(Int)        // 0..255
    case rgb(Int, Int, Int)  // true colour
}

struct CellAttr: Equatable {
    var bold = false
    var faint = false
    var underline = false
    var blink = false
    var reverse = false
    var invisible = false
    var fg: TermColor = .defaultColor
    var bg: TermColor = .defaultColor
}

struct TermCell: Equatable {
    var ch: Character = " "
    var attr = CellAttr()
    // true for the right half of a double-width character (not drawn)
    var wideTrailer = false
}

protocol TerminalEmulatorDelegate: AnyObject {
    func terminalSend(_ data: Data)          // reports back to the backend
    func terminalBell()
    func terminalSetTitle(_ title: String)
    func terminalNeedsRedraw()
}

final class TerminalEmulator {
    weak var delegate: TerminalEmulatorDelegate?

    private(set) var cols: Int
    private(set) var rows: Int

    // Visible screen and scrollback.
    private(set) var screen: [[TermCell]] = []
    private(set) var scrollback: [[TermCell]] = []
    var maxScrollback: Int

    // Alternate screen support.
    private var altScreen: [[TermCell]]? = nil
    private var savedPrimary: [[TermCell]]? = nil

    // Cursor and saved cursor.
    private(set) var cx = 0
    private(set) var cy = 0
    private var savedCx = 0, savedCy = 0
    private var savedAttr = CellAttr()
    private var wrapNext = false   // deferred wrap, as in xterm

    // Current drawing attributes.
    private var attr = CellAttr()

    // Modes.
    var wrapMode = true
    var originMode = false
    var insertMode = false
    var appCursorKeys = false
    var appKeypad = false
    var autoNewline = false      // LNM
    private(set) var cursorVisible = true
    var reverseVideo = false
    private(set) var mouseReporting = 0   // 0 none, else the DECSET number
    private(set) var mouseSGR = false
    private(set) var bracketedPaste = false
    private(set) var usingAltScreen = false

    // Scroll region (0-based, inclusive).
    private var scrollTop = 0
    private var scrollBot = 0

    // Tab stops.
    private var tabs: [Bool] = []

    // Charset designation for line drawing (G0/G1).
    private var g: [Bool] = [false, false]   // true means VT100 line-drawing set
    private var gl = 0

    // Config-driven behaviour.
    var answerback = "PuTTY"
    var bce = true
    var utf8 = true

    // UTF-8 decoder state.
    private var utf8Rem = 0
    private var utf8Acc: UInt32 = 0
    private var utf8Min: UInt32 = 0

    // Parser state.
    private enum PState { case ground, esc, csi, osc, oscEsc, charset(Int), hash, ignore }
    private var pstate: PState = .ground
    private var params: [Int] = []
    private var paramStr = ""
    private var csiPrivate = false
    private var oscString = ""
    private var oscEscPending = false

    init(cols: Int, rows: Int, scrollback: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.maxScrollback = max(0, scrollback)
        self.scrollTop = 0
        self.scrollBot = self.rows - 1
        reset(hard: true)
    }

    // MARK: - Public

    func reset(hard: Bool) {
        attr = CellAttr()
        cx = 0; cy = 0; wrapNext = false
        originMode = false; insertMode = false
        appCursorKeys = false; appKeypad = false; autoNewline = false
        cursorVisible = true; reverseVideo = false
        g = [false, false]; gl = 0
        scrollTop = 0; scrollBot = rows - 1
        if hard {
            screen = Self.blank(cols: cols, rows: rows)
            altScreen = nil; usingAltScreen = false
            scrollback.removeAll()
        }
        resetTabs()
        pstate = .ground
        delegate?.terminalNeedsRedraw()
    }

    func resize(cols newC: Int, rows newR: Int) {
        let newC = max(1, newC), newR = max(1, newR)
        if newC == cols && newR == rows { return }
        var ns = Self.blank(cols: newC, rows: newR)
        // Copy what we can (top-left aligned).
        for y in 0..<min(newR, screen.count) {
            for x in 0..<min(newC, screen[y].count) { ns[y][x] = screen[y][x] }
        }
        screen = ns
        cols = newC; rows = newR
        scrollTop = 0; scrollBot = rows - 1
        cx = min(cx, cols - 1); cy = min(cy, rows - 1)
        resetTabs()
        delegate?.terminalNeedsRedraw()
    }

    /// Feed received bytes through the parser.
    func feed(_ data: Data) {
        for b in data { step(b) }
        delegate?.terminalNeedsRedraw()
    }

    /// All lines currently visible via the scroll offset, for drawing.
    func lineForDisplay(absoluteRow r: Int) -> [TermCell] {
        if r < scrollback.count { return scrollback[r] }
        let s = r - scrollback.count
        if s < screen.count { return screen[s] }
        return Self.blankRow(cols: cols)
    }

    var totalRows: Int { scrollback.count + rows }

    func cursorScreenPosition() -> (x: Int, y: Int) { (cx, cy) }

    // MARK: - Grid helpers
    static func blankRow(cols: Int) -> [TermCell] { Array(repeating: TermCell(), count: cols) }
    static func blank(cols: Int, rows: Int) -> [[TermCell]] {
        Array(repeating: blankRow(cols: cols), count: rows)
    }

    private func resetTabs() {
        tabs = Array(repeating: false, count: cols)
        var i = 0
        while i < cols { tabs[i] = true; i += 8 }
    }

    private func eraseCell() -> TermCell {
        var c = TermCell()
        if bce { c.attr.bg = attr.bg }   // background-colour erase
        return c
    }

    // MARK: - Parser
    private func step(_ b: UInt8) {
        switch pstate {
        case .ground:    ground(b)
        case .esc:       escByte(b)
        case .csi:       csiByte(b)
        case .osc:       oscByte(b)
        case .oscEsc:    oscEscByte(b)
        case .charset(let slot): g[slot] = (b == 0x30); pstate = .ground  // '0' = line drawing
        case .hash:      if b == 0x38 { alignmentTest() }; pstate = .ground
        case .ignore:    if b == 0x5c || b == 0x07 { pstate = .ground }    // skip to ST/BEL
        }
    }

    private func ground(_ b: UInt8) {
        if b < 0x20 {
            control(b); return
        }
        if utf8 {
            if utf8Rem > 0 {
                if b & 0xc0 == 0x80 {
                    utf8Acc = (utf8Acc << 6) | UInt32(b & 0x3f)
                    utf8Rem -= 1
                    if utf8Rem == 0 {
                        if utf8Acc >= utf8Min, let sc = Unicode.Scalar(utf8Acc) {
                            putChar(Character(sc))
                        } else { putChar("\u{fffd}") }
                    }
                    return
                } else { utf8Rem = 0; putChar("\u{fffd}") /* fallthrough reprocess */ }
            }
            if b < 0x80 {
                putByteChar(b)
            } else if b & 0xe0 == 0xc0 {
                utf8Acc = UInt32(b & 0x1f); utf8Rem = 1; utf8Min = 0x80
            } else if b & 0xf0 == 0xe0 {
                utf8Acc = UInt32(b & 0x0f); utf8Rem = 2; utf8Min = 0x800
            } else if b & 0xf8 == 0xf0 {
                utf8Acc = UInt32(b & 0x07); utf8Rem = 3; utf8Min = 0x10000
            } else {
                putChar("\u{fffd}")
            }
        } else {
            putByteChar(b)
        }
    }

    private func putByteChar(_ b: UInt8) {
        if g[gl], let mapped = Self.lineDraw[b] { putChar(mapped); return }
        putChar(Character(UnicodeScalar(b)))
    }

    private func control(_ b: UInt8) {
        switch b {
        case 0x07: delegate?.terminalBell()
        case 0x08: // BS
            if cx > 0 { cx -= 1 }; wrapNext = false
        case 0x09: // HT
            tab()
        case 0x0a, 0x0b, 0x0c: // LF/VT/FF
            lineFeed()
            if autoNewline { cx = 0 }
        case 0x0d: cx = 0; wrapNext = false   // CR
        case 0x0e: gl = 1                      // SO -> G1
        case 0x0f: gl = 0                      // SI -> G0
        case 0x1b: pstate = .esc               // ESC
        default: break
        }
    }

    private func escByte(_ b: UInt8) {
        pstate = .ground
        switch b {
        case 0x5b: params = []; paramStr = ""; csiPrivate = false; pstate = .csi   // [
        case 0x5d: oscString = ""; pstate = .osc                                   // ]
        case 0x28: pstate = .charset(0)                                            // ( G0
        case 0x29: pstate = .charset(1)                                            // ) G1
        case 0x3d: appKeypad = true                                                // =
        case 0x3e: appKeypad = false                                               // >
        case 0x37: savedCx = cx; savedCy = cy; savedAttr = attr                    // 7 DECSC
        case 0x38: cx = savedCx; cy = savedCy; attr = savedAttr; wrapNext = false  // 8 DECRC
        case 0x44: lineFeed()                                                      // D IND
        case 0x4d: reverseIndex()                                                  // M RI
        case 0x45: cx = 0; lineFeed()                                              // E NEL
        case 0x63: reset(hard: true)                                               // c RIS
        case 0x23: pstate = .hash                                                  // #
        case 0x5c: break                                                           // ST
        default: break
        }
    }

    private func csiByte(_ b: UInt8) {
        if b == 0x3f && params.isEmpty && paramStr.isEmpty { csiPrivate = true; return }  // ?
        if (0x30...0x39).contains(b) { paramStr.append(Character(UnicodeScalar(b))); return }
        if b == 0x3b { params.append(Int(paramStr) ?? 0); paramStr = ""; return }        // ;
        if (0x20...0x2f).contains(b) { return }  // intermediate, ignored
        // final byte
        if !paramStr.isEmpty { params.append(Int(paramStr) ?? 0); paramStr = "" }
        dispatchCSI(b)
        pstate = .ground
    }

    private func param(_ i: Int, _ def: Int) -> Int {
        if i < params.count { return params[i] == 0 ? def : params[i] }
        return def
    }
    private func paramRaw(_ i: Int, _ def: Int) -> Int {
        if i < params.count { return params[i] }
        return def
    }

    private func dispatchCSI(_ b: UInt8) {
        switch b {
        case 0x41: moveCursor(dx: 0, dy: -param(0,1))                 // A up
        case 0x42: moveCursor(dx: 0, dy: param(0,1))                  // B down
        case 0x43: moveCursor(dx: param(0,1), dy: 0)                  // C right
        case 0x44: moveCursor(dx: -param(0,1), dy: 0)                 // D left
        case 0x45: cx = 0; moveCursor(dx: 0, dy: param(0,1))          // E
        case 0x46: cx = 0; moveCursor(dx: 0, dy: -param(0,1))         // F
        case 0x47, 0x60: setCursor(x: param(0,1)-1, y: cy)           // G / `
        case 0x64: setCursor(x: cx, y: param(0,1)-1)                 // d
        case 0x48, 0x66: setCursor(x: param(1,1)-1, y: param(0,1)-1) // H / f
        case 0x4a: eraseDisplay(paramRaw(0,0))                       // J
        case 0x4b: eraseLine(paramRaw(0,0))                          // K
        case 0x4d: deleteLines(param(0,1))                           // M
        case 0x4c: insertLines(param(0,1))                           // L
        case 0x40: insertChars(param(0,1))                           // @
        case 0x50: deleteChars(param(0,1))                           // P
        case 0x58: eraseChars(param(0,1))                            // X
        case 0x53: scrollUp(param(0,1))                              // S
        case 0x54: scrollDown(param(0,1))                            // T
        case 0x6d: applySGR()                                        // m
        case 0x72: setScrollRegion()                                 // r
        case 0x68: setMode(true)                                     // h
        case 0x6c: setMode(false)                                    // l
        case 0x73: savedCx = cx; savedCy = cy; savedAttr = attr      // s
        case 0x75: cx = savedCx; cy = savedCy; attr = savedAttr      // u
        case 0x6e: deviceStatus(param(0,0))                          // n
        case 0x63: deviceAttributes()                                // c
        case 0x67: if param(0,0) == 3 { tabs = Array(repeating:false,count:cols) } else if cx < cols { tabs[cx] = false } // g
        default: break
        }
    }

    // MARK: - Printing
    private func putChar(_ ch: Character) {
        if wrapNext && wrapMode {
            cx = 0
            lineFeed()
            wrapNext = false
        }
        if cx >= cols { cx = cols - 1 }
        if insertMode {
            var row = screen[cy]
            row.insert(TermCell(), at: cx)
            row.removeLast()
            screen[cy] = row
        }
        var cell = TermCell()
        cell.ch = ch
        cell.attr = attr
        screen[cy][cx] = cell
        if cx == cols - 1 {
            wrapNext = true
        } else {
            cx += 1
        }
    }

    private func tab() {
        if cx >= cols - 1 { return }
        var x = cx + 1
        while x < cols - 1 && !tabs[x] { x += 1 }
        cx = x
        wrapNext = false
    }

    private func lineFeed() {
        if cy == scrollBot {
            scrollRegionUp(1)
        } else if cy < rows - 1 {
            cy += 1
        }
        wrapNext = false
    }

    private func reverseIndex() {
        if cy == scrollTop {
            scrollRegionDown(1)
        } else if cy > 0 {
            cy -= 1
        }
    }

    // MARK: - Scrolling
    private func scrollRegionUp(_ n: Int) {
        let n = max(1, n)
        for _ in 0..<n {
            if scrollTop == 0 && scrollBot == rows - 1 && !usingAltScreen {
                // push top line into scrollback
                scrollback.append(screen[0])
                if scrollback.count > maxScrollback {
                    scrollback.removeFirst(scrollback.count - maxScrollback)
                }
                screen.removeFirst()
                screen.append(eraseRow())
            } else {
                screen.remove(at: scrollTop)
                screen.insert(eraseRow(), at: scrollBot)
            }
        }
    }
    private func scrollRegionDown(_ n: Int) {
        let n = max(1, n)
        for _ in 0..<n {
            screen.remove(at: scrollBot)
            screen.insert(eraseRow(), at: scrollTop)
        }
    }
    private func scrollUp(_ n: Int) { scrollRegionUp(n) }
    private func scrollDown(_ n: Int) { scrollRegionDown(n) }

    private func eraseRow() -> [TermCell] { Array(repeating: eraseCell(), count: cols) }

    // MARK: - Cursor movement
    private func moveCursor(dx: Int, dy: Int) {
        cx = min(max(0, cx + dx), cols - 1)
        let top = originMode ? scrollTop : 0
        let bot = originMode ? scrollBot : rows - 1
        cy = min(max(top, cy + dy), bot)
        wrapNext = false
    }
    // Absolute positioning (CUP/HVP/CHA/VPA); y is relative to the scroll
    // region when origin mode is on.
    private func setCursor(x: Int, y: Int) {
        cx = min(max(0, x), cols - 1)
        if originMode {
            cy = min(max(scrollTop, scrollTop + y), scrollBot)
        } else {
            cy = min(max(0, y), rows - 1)
        }
        wrapNext = false
    }

    // MARK: - Erase
    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for y in (cy+1)..<rows { screen[y] = eraseRow() }
        case 1:
            eraseLine(1)
            for y in 0..<cy { screen[y] = eraseRow() }
        case 2, 3:
            for y in 0..<rows { screen[y] = eraseRow() }
        default: break
        }
    }
    private func eraseLine(_ mode: Int) {
        switch mode {
        case 0: for x in cx..<cols { screen[cy][x] = eraseCell() }
        case 1: for x in 0...min(cx, cols-1) { screen[cy][x] = eraseCell() }
        case 2: for x in 0..<cols { screen[cy][x] = eraseCell() }
        default: break
        }
    }
    private func eraseChars(_ n: Int) {
        let end = min(cx + n, cols)
        for x in cx..<end { screen[cy][x] = eraseCell() }
    }

    // MARK: - Insert/delete
    private func insertChars(_ n: Int) {
        var row = screen[cy]
        for _ in 0..<n { row.insert(eraseCell(), at: cx); row.removeLast() }
        screen[cy] = row
    }
    private func deleteChars(_ n: Int) {
        var row = screen[cy]
        for _ in 0..<min(n, cols - cx) { row.remove(at: cx); row.append(eraseCell()) }
        screen[cy] = row
    }
    private func insertLines(_ n: Int) {
        guard cy >= scrollTop && cy <= scrollBot else { return }
        for _ in 0..<n { screen.remove(at: scrollBot); screen.insert(eraseRow(), at: cy) }
    }
    private func deleteLines(_ n: Int) {
        guard cy >= scrollTop && cy <= scrollBot else { return }
        for _ in 0..<n { screen.remove(at: cy); screen.insert(eraseRow(), at: scrollBot) }
    }

    // MARK: - SGR
    private func applySGR() {
        if params.isEmpty { params = [0] }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0: attr = CellAttr()
            case 1: attr.bold = true
            case 2: attr.faint = true
            case 4: attr.underline = true
            case 5, 6: attr.blink = true
            case 7: attr.reverse = true
            case 8: attr.invisible = true
            case 22: attr.bold = false; attr.faint = false
            case 24: attr.underline = false
            case 25: attr.blink = false
            case 27: attr.reverse = false
            case 28: attr.invisible = false
            case 30...37: attr.fg = .indexed(p - 30)
            case 39: attr.fg = .defaultColor
            case 40...47: attr.bg = .indexed(p - 40)
            case 49: attr.bg = .defaultColor
            case 90...97: attr.fg = .indexed(p - 90 + 8)
            case 100...107: attr.bg = .indexed(p - 100 + 8)
            case 38, 48:
                // extended colour: 38;5;n  or  38;2;r;g;b
                if i + 1 < params.count {
                    let kind = params[i+1]
                    if kind == 5, i + 2 < params.count {
                        let c = TermColor.indexed(params[i+2])
                        if p == 38 { attr.fg = c } else { attr.bg = c }
                        i += 2
                    } else if kind == 2, i + 4 < params.count {
                        let c = TermColor.rgb(params[i+2], params[i+3], params[i+4])
                        if p == 38 { attr.fg = c } else { attr.bg = c }
                        i += 4
                    }
                }
            default: break
            }
            i += 1
        }
    }

    // MARK: - Modes
    private func setMode(_ on: Bool) {
        for p in (params.isEmpty ? [0] : params) {
            if csiPrivate {
                switch p {
                case 1: appCursorKeys = on
                case 3: /* 132/80 col - ignore but clear */ eraseDisplay(2); setCursor(x:0,y:0)
                case 6: originMode = on; setCursor(x: 0, y: 0)
                case 7: wrapMode = on
                case 12: /* cursor blink */ break
                case 25: cursorVisible = on
                case 1000: mouseReporting = on ? 1000 : 0
                case 1002: mouseReporting = on ? 1002 : 0
                case 1003: mouseReporting = on ? 1003 : 0
                case 1006: mouseSGR = on
                case 1049, 47, 1047:
                    setAltScreen(on)
                case 2004: bracketedPaste = on
                default: break
                }
            } else {
                switch p {
                case 4: insertMode = on
                case 20: autoNewline = on
                default: break
                }
            }
        }
    }

    private func setAltScreen(_ on: Bool) {
        if on && !usingAltScreen {
            savedPrimary = screen
            screen = Self.blank(cols: cols, rows: rows)
            usingAltScreen = true
            setCursor(x: 0, y: 0)
        } else if !on && usingAltScreen {
            if let p = savedPrimary { screen = p }
            savedPrimary = nil
            usingAltScreen = false
        }
    }

    private func setScrollRegion() {
        let top = param(0,1) - 1
        let bot = paramRaw(1, rows) == 0 ? rows - 1 : paramRaw(1, rows) - 1
        if top < bot && bot < rows {
            scrollTop = max(0, top)
            scrollBot = min(rows - 1, bot)
            setCursor(x: 0, y: 0)
        }
    }

    // MARK: - Reports
    private func deviceStatus(_ p: Int) {
        switch p {
        case 5: send("\u{1b}[0n")                       // OK
        case 6: send("\u{1b}[\(cy+1);\(cx+1)R")         // cursor position
        default: break
        }
    }
    private func deviceAttributes() {
        send("\u{1b}[?6c")   // VT102, matching PuTTY's id_string default
    }

    private func alignmentTest() {
        for y in 0..<rows { screen[y] = Array(repeating: { var c = TermCell(); c.ch = "E"; return c }(), count: cols) }
    }

    private func send(_ s: String) { delegate?.terminalSend(Data(s.utf8)) }

    // MARK: - OSC
    private func oscByte(_ b: UInt8) {
        if b == 0x07 { finishOSC(); pstate = .ground; return }       // BEL
        if b == 0x1b { pstate = .oscEsc; return }                    // ESC (maybe ST)
        oscString.append(Character(UnicodeScalar(b)))
    }
    private func oscEscByte(_ b: UInt8) {
        if b == 0x5c { finishOSC() }                                 // ST
        pstate = .ground
    }
    private func finishOSC() {
        // Format: Ps ; Pt
        guard let semi = oscString.firstIndex(of: ";") else { return }
        let code = String(oscString[oscString.startIndex..<semi])
        let text = String(oscString[oscString.index(after: semi)...])
        if code == "0" || code == "2" {
            delegate?.terminalSetTitle(text)
        }
        oscString = ""
    }

    // VT100 line-drawing map for bytes 0x60..0x7e in the special graphics set.
    static let lineDraw: [UInt8: Character] = {
        var m: [UInt8: Character] = [:]
        // DEC special graphics, bytes 0x60 ('`') .. 0x7e ('~').
        let chars = "◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·"
        var b: UInt8 = 0x60
        for c in chars { m[b] = c; b += 1 }
        return m
    }()
}
