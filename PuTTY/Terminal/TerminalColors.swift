import AppKit

// PuTTY's palette.  The first 22 entries are the configurable defaults from
// settings.c; after them come the 6x6x6 colour cube and the greyscale ramp
// used for xterm 256-colour mode.
struct TerminalPalette {
    // Named indices into the first 22 entries (putty.h CONF_COLOUR_LIST order).
    enum Named: Int {
        case fg = 0, fgBold, bg, bgBold, cursorFg, cursorBg
        case black, blackBold, red, redBold, green, greenBold
        case yellow, yellowBold, blue, blueBold, magenta, magentaBold
        case cyan, cyanBold, white, whiteBold
    }

    // The 22 default RGB triples straight from settings.c.
    static let defaults: [(Int, Int, Int)] = [
        (187,187,187), (255,255,255), (0,0,0), (85,85,85), (0,0,0),
        (0,255,0), (0,0,0), (85,85,85), (187,0,0), (255,85,85),
        (0,187,0), (85,255,85), (187,187,0), (255,255,85), (0,0,187),
        (85,85,255), (187,0,187), (255,85,255), (0,187,187),
        (85,255,255), (187,187,187), (255,255,255)
    ]

    var rgb: [(Int, Int, Int)]

    init(conf: Conf) {
        rgb = TerminalPalette.defaults
        // Apply any per-slot overrides the Colours panel saved as "Colour{n}".
        for slot in 0..<rgb.count {
            let s = conf.getStr("Colour\(slot)")
            if !s.isEmpty {
                let parts = s.split(separator: ",").compactMap { Int($0) }
                if parts.count == 3 { rgb[slot] = (parts[0], parts[1], parts[2]) }
            }
        }
        rgb.reserveCapacity(262)
        // 6x6x6 colour cube (xterm colours 16..231)
        let steps = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]
        for r in steps { for g in steps { for b in steps { rgb.append((r, g, b)) } } }
        // greyscale ramp (232..255)
        for i in 0..<24 { let v = 8 + i * 10; rgb.append((v, v, v)) }
    }

    // Map an ANSI colour index 0..15 (used by the emulator) to palette slot.
    static func ansiSlot(_ idx: Int, bold: Bool) -> Int {
        // indices 0..7 normal, 8..15 bold, matching PuTTY's black..white layout
        let base = idx & 7
        let order: [Named] = [.black, .red, .green, .yellow, .blue, .magenta, .cyan, .white]
        let n = order[base]
        let slot = n.rawValue + (bold || idx >= 8 ? 1 : 0)
        return slot
    }

    func nsColor(_ slot: Int) -> NSColor {
        guard slot >= 0 && slot < rgb.count else { return .black }
        let (r, g, b) = rgb[slot]
        return NSColor(srgbRed: CGFloat(r)/255.0, green: CGFloat(g)/255.0,
                       blue: CGFloat(b)/255.0, alpha: 1.0)
    }
}
