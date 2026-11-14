import AppKit

protocol TerminalViewInput: AnyObject {
    func terminalViewSend(_ bytes: [UInt8])
    func terminalViewPaste(_ text: String)
    func terminalViewContextMenu(_ event: NSEvent) -> NSMenu?
}

/// Draws the emulator's grid with a monospaced font and handles keyboard,
/// mouse selection and scrollback scrolling.
final class TerminalView: NSView {
    let term: TerminalEmulator
    let conf: Conf
    weak var input: TerminalViewInput?
    var palette: TerminalPalette

    private var font: NSFont
    private var boldFont: NSFont
    private var cellW: CGFloat = 8
    private var cellH: CGFloat = 16
    private var ascent: CGFloat = 12
    private let borderInset: CGFloat

    // Scrollback: number of lines scrolled up from the bottom.
    private var scrollOffset = 0

    // Selection in absolute (scrollback-inclusive) coordinates.
    private var selAnchor: (row: Int, col: Int)?
    private var selPoint: (row: Int, col: Int)?

    private var blinkOn = true
    private var blinkTimer: Timer?

    init(term: TerminalEmulator, conf: Conf) {
        self.term = term
        self.conf = conf
        self.palette = TerminalPalette(conf: conf)
        self.borderInset = CGFloat(conf.getInt(K.windowBorder))
        let (f, b) = TerminalView.resolveFonts(conf.getStr(K.font))
        self.font = f; self.boldFont = b
        super.init(frame: .zero)
        measureFont()
        wantsLayer = true
        layer?.backgroundColor = palette.nsColor(TerminalPalette.Named.bg.rawValue).cgColor
        startBlink()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { blinkTimer?.invalidate() }

    static func resolveFonts(_ spec: String) -> (NSFont, NSFont) {
        // spec is like "Menlo 12"
        var name = "Menlo"; var size: CGFloat = 12
        let parts = spec.split(separator: " ")
        if parts.count >= 2, let s = Double(parts.last!) {
            size = CGFloat(s)
            name = parts.dropLast().joined(separator: " ")
        } else if !spec.isEmpty { name = spec }
        let f = NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let b = NSFont(name: name + "-Bold", size: size)
            ?? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        return (f, b)
    }

    private func measureFont() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let w = ("W" as NSString).size(withAttributes: attrs).width
        cellW = ceil(w)
        cellH = ceil(font.ascender - font.descender + font.leading) + 1
        ascent = ceil(font.ascender)
    }

    var terminalSize: NSSize {
        NSSize(width: CGFloat(term.cols) * cellW + 2 * borderInset,
               height: CGFloat(term.rows) * cellH + 2 * borderInset)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bg = palette.nsColor(TerminalPalette.Named.bg.rawValue)
        bg.setFill()
        ctx.fill(bounds)

        let totalRows = term.totalRows
        let firstVisibleAbs = max(0, totalRows - term.rows - scrollOffset)

        for screenRow in 0..<term.rows {
            let absRow = firstVisibleAbs + screenRow
            if absRow >= totalRows { break }
            let line = term.lineForDisplay(absoluteRow: absRow)
            drawLine(line, screenRow: screenRow, absRow: absRow, ctx: ctx)
        }

        drawCursor(firstVisibleAbs: firstVisibleAbs, ctx: ctx)
    }

    private func drawLine(_ line: [TermCell], screenRow: Int, absRow: Int, ctx: CGContext) {
        let y = borderInset + CGFloat(screenRow) * cellH
        var col = 0
        while col < line.count && col < term.cols {
            let cell = line[col]
            if cell.wideTrailer { col += 1; continue }
            let x = borderInset + CGFloat(col) * cellW
            let (fg, bgc) = colors(for: cell.attr)

            // background
            if bgc != palette.nsColor(TerminalPalette.Named.bg.rawValue) || isSelected(absRow: absRow, col: col) {
                let drawBg = isSelected(absRow: absRow, col: col) ? selectionColor() : bgc
                drawBg.setFill()
                ctx.fill(NSRect(x: x, y: y, width: cellW, height: cellH))
            }

            if cell.ch != " " && !cell.attr.invisible &&
                !(cell.attr.blink && conf.getBool(K.blinkText) && !blinkOn) {
                let useFont = cell.attr.bold && conf.getInt(K.boldStyle) != BoldStyle.colour.rawValue ? boldFont : font
                let str = NSAttributedString(string: String(cell.ch), attributes: [
                    .font: useFont,
                    .foregroundColor: fg
                ])
                str.draw(at: NSPoint(x: x, y: y + (cellH - ascent - 1)))
                if cell.attr.underline {
                    fg.setStroke()
                    let uy = y + ascent + 1
                    ctx.move(to: CGPoint(x: x, y: uy))
                    ctx.addLine(to: CGPoint(x: x + cellW, y: uy))
                    ctx.strokePath()
                }
            }
            col += 1
        }
    }

    private func drawCursor(firstVisibleAbs: Int, ctx: CGContext) {
        guard term.cursorVisible, scrollOffset == 0 else { return }
        let (cxp, cyp) = term.cursorScreenPosition()
        let x = borderInset + CGFloat(cxp) * cellW
        let y = borderInset + CGFloat(cyp) * cellH
        let color = palette.nsColor(TerminalPalette.Named.cursorBg.rawValue)
        color.setFill()
        let focused = (window?.firstResponder === self)
        switch CursorType(rawValue: conf.getInt(K.cursorType)) ?? .block {
        case .block:
            if focused {
                ctx.fill(NSRect(x: x, y: y, width: cellW, height: cellH))
            } else {
                ctx.stroke(NSRect(x: x+0.5, y: y+0.5, width: cellW-1, height: cellH-1))
            }
        case .underline:
            ctx.fill(NSRect(x: x, y: y + cellH - 2, width: cellW, height: 2))
        case .verticalLine:
            ctx.fill(NSRect(x: x, y: y, width: 2, height: cellH))
        }
    }

    private func colors(for attr: CellAttr) -> (NSColor, NSColor) {
        func resolve(_ c: TermColor, defaultSlot: Int, boldBump: Bool) -> NSColor {
            switch c {
            case .defaultColor:
                return palette.nsColor(defaultSlot)
            case .indexed(let i):
                if i < 16 {
                    let bold = (i < 8) && boldBump && conf.getInt(K.boldStyle) != BoldStyle.font.rawValue
                    return palette.nsColor(TerminalPalette.ansiSlot(i, bold: bold))
                }
                return palette.nsColor(i >= 16 && i < 256 ? 22 + (i - 16) : 22)
            case .rgb(let r, let g, let b):
                return NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
            }
        }
        var fg = resolve(attr.fg, defaultSlot: attr.bold ? TerminalPalette.Named.fgBold.rawValue : TerminalPalette.Named.fg.rawValue, boldBump: attr.bold)
        var bg = resolve(attr.bg, defaultSlot: TerminalPalette.Named.bg.rawValue, boldBump: false)
        if attr.reverse != term.reverseVideo { swap(&fg, &bg) }
        if attr.faint { fg = fg.withAlphaComponent(0.6) }
        return (fg, bg)
    }

    private func selectionColor() -> NSColor {
        NSColor.selectedTextBackgroundColor
    }

    // MARK: selection
    private func isSelected(absRow: Int, col: Int) -> Bool {
        guard let a = selAnchor, let p = selPoint else { return false }
        let (lo, hi) = orderedSelection(a, p)
        if absRow < lo.row || absRow > hi.row { return false }
        if lo.row == hi.row { return col >= lo.col && col < hi.col }
        if absRow == lo.row { return col >= lo.col }
        if absRow == hi.row { return col < hi.col }
        return true
    }
    private func orderedSelection(_ a: (row: Int, col: Int), _ b: (row: Int, col: Int)) -> ((row:Int,col:Int),(row:Int,col:Int)) {
        if a.row < b.row || (a.row == b.row && a.col <= b.col) { return (a, b) }
        return (b, a)
    }

    private func cellAt(_ point: NSPoint) -> (row: Int, col: Int) {
        let totalRows = term.totalRows
        let firstVisibleAbs = max(0, totalRows - term.rows - scrollOffset)
        let col = max(0, min(term.cols, Int((point.x - borderInset) / cellW)))
        let screenRow = max(0, min(term.rows - 1, Int((point.y - borderInset) / cellH)))
        return (firstVisibleAbs + screenRow, col)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        selAnchor = cellAt(p); selPoint = selAnchor
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        selPoint = cellAt(p)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if conf.getBool(K.mouseautocopy) { copySelection(nil) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = input?.terminalViewContextMenu(event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click paste, like X11/PuTTY.
        if let s = NSPasteboard.general.string(forType: .string) {
            input?.terminalViewPaste(s)
        }
    }

    // MARK: keyboard
    override func keyDown(with event: NSEvent) {
        if conf.getBool(K.scrollOnKey) { scrollOffset = 0 }
        let kb = Keyboard(term: term, conf: conf)
        if let bytes = kb.bytes(for: event) {
            input?.terminalViewSend(bytes)
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let lines = Int(event.scrollingDeltaY / 4)
        if lines != 0 {
            let maxOff = term.scrollback.count
            scrollOffset = max(0, min(maxOff, scrollOffset + lines))
            needsDisplay = true
        }
    }

    // MARK: menu actions
    @objc func copySelection(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    @objc func pasteSelection(_ sender: Any?) {
        if let s = NSPasteboard.general.string(forType: .string) {
            input?.terminalViewPaste(s)
        }
    }
    @objc func copyAll(_ sender: Any?) {
        var lines: [String] = []
        for r in 0..<term.totalRows {
            lines.append(rowText(term.lineForDisplay(absoluteRow: r)))
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }
    @objc func clearScrollbackAction(_ sender: Any?) { /* handled by controller */ }

    private func selectedText() -> String? {
        guard let a = selAnchor, let p = selPoint else { return nil }
        let (lo, hi) = orderedSelection(a, p)
        var result = ""
        for row in lo.row...hi.row {
            let line = term.lineForDisplay(absoluteRow: row)
            let startCol = (row == lo.row) ? lo.col : 0
            let endCol = (row == hi.row) ? hi.col : line.count
            result += rowText(Array(line[min(startCol,line.count)..<min(endCol,line.count)]))
            if row != hi.row { result += "\n" }
        }
        return result
    }
    private func rowText(_ line: [TermCell]) -> String {
        var s = ""
        for cell in line where !cell.wideTrailer { s.append(cell.ch) }
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    // MARK: refresh
    func refresh() {
        if conf.getBool(K.scrollOnDisp) { scrollOffset = 0 }
        needsDisplay = true
    }

    func reloadFontAndPalette() {
        palette = TerminalPalette(conf: conf)
        let (f, b) = TerminalView.resolveFonts(conf.getStr(K.font))
        font = f; boldFont = b
        measureFont()
        layer?.backgroundColor = palette.nsColor(TerminalPalette.Named.bg.rawValue).cgColor
        needsDisplay = true
    }

    var charCell: NSSize { NSSize(width: cellW, height: cellH) }

    private func startBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.blinkOn.toggle()
            if self.conf.getBool(K.blinkText) || self.conf.getBool(K.blinkCur) {
                self.needsDisplay = true
            }
        }
    }
}
