import Foundation

/// The line discipline, ported in spirit from ldisc.c.  It decides whether to
/// echo typed characters locally and whether to perform local line editing
/// (so that Raw/Telnet/Rlogin sessions behave sensibly), honouring the
/// Terminal panel's "Local echo" and "Local line editing" tri-state options.
final class Ldisc {
    private let conf: Conf
    private weak var backend: Backend?
    private let toTerminal: (Data) -> Void

    private var echoing = false
    private var editing = false
    private var lineBuffer: [UInt8] = []

    init(conf: Conf, backend: Backend, toTerminal: @escaping (Data) -> Void) {
        self.conf = conf
        self.backend = backend
        self.toTerminal = toTerminal
        recompute()
    }

    func recompute() {
        guard let backend = backend else { return }
        switch TriState(rawValue: conf.getInt(K.localecho)) ?? .auto {
        case .forceOn: echoing = true
        case .forceOff: echoing = false
        case .auto: echoing = backend.ldiscWantsEcho()
        }
        switch TriState(rawValue: conf.getInt(K.localedit)) ?? .auto {
        case .forceOn: editing = true
        case .forceOff: editing = false
        case .auto: editing = backend.ldiscWantsEdit()
        }
    }

    /// Called when the server's negotiation changes (e.g. Telnet WILL ECHO).
    func setServerEcho(_ serverEchoes: Bool) {
        if (TriState(rawValue: conf.getInt(K.localecho)) ?? .auto) == .auto {
            echoing = !serverEchoes
        }
        if (TriState(rawValue: conf.getInt(K.localedit)) ?? .auto) == .auto {
            editing = !serverEchoes
        }
    }

    func send(_ bytes: [UInt8], interactive: Bool) {
        guard let backend = backend else { return }
        if editing {
            for b in bytes { editByte(b, backend: backend) }
        } else {
            if echoing { toTerminal(Data(bytes)) }
            backend.send(Data(bytes))
        }
    }

    private func editByte(_ b: UInt8, backend: Backend) {
        switch b {
        case 0x0d, 0x0a:   // CR / LF -> commit line
            lineBuffer.append(0x0d)
            if echoing { toTerminal(Data([0x0d, 0x0a])) }
            flushLine(backend)
        case 0x7f, 0x08:   // backspace
            if !lineBuffer.isEmpty {
                lineBuffer.removeLast()
                if echoing { toTerminal(Data([0x08, 0x20, 0x08])) }
            }
        case 0x15:         // Ctrl-U: kill line
            if echoing {
                for _ in lineBuffer { toTerminal(Data([0x08, 0x20, 0x08])) }
            }
            lineBuffer.removeAll()
        case 0x03:         // Ctrl-C: pass straight through
            backend.send(Data([b]))
            lineBuffer.removeAll()
        default:
            lineBuffer.append(b)
            if echoing { toTerminal(Data([b])) }
        }
    }

    private func flushLine(_ backend: Backend) {
        var out = lineBuffer
        // Translate the trailing CR according to protocol, like ldisc.c.
        if conf.protocolValue == .raw {
            if out.last == 0x0d { out.removeLast(); out += [0x0d, 0x0a] }
        }
        backend.send(Data(out))
        lineBuffer.removeAll()
    }
}
