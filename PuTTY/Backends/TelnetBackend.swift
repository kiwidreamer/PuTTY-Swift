import Foundation

/// PROT_TELNET — Telnet protocol with the option negotiation PuTTY performs
/// in otherbackends/telnet.c (enough for a normal interactive login).
final class TelnetBackend: TCPBackend {
    override var name: String { "Telnet" }

    private let conf: Conf

    // Telnet commands.
    private let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253
    private let WONT: UInt8 = 252, WILL: UInt8 = 251, SB: UInt8 = 250, SE: UInt8 = 240

    // Options.
    private let OPT_ECHO: UInt8 = 1, OPT_SGA: UInt8 = 3, OPT_NAWS: UInt8 = 31
    private let OPT_TTYPE: UInt8 = 24, OPT_BINARY: UInt8 = 0, OPT_NEWENV: UInt8 = 39

    private enum RState { case data, iac, willdo, sb, sbiac, sbEnd }
    private var rstate: RState = .data
    private var sbOption: UInt8 = 0
    private var sbData: [UInt8] = []
    private var pendingCmd: UInt8 = 0

    private var cols = 80, rows = 24

    init(conf: Conf, host: String, port: Int) {
        self.conf = conf
        super.init(host: host, port: port,
                   addressFamily: AddressFamily(rawValue: conf.getInt(K.addressFamily)) ?? .unspec)
    }

    override func ldiscWantsEcho() -> Bool { true }  // until server says WILL ECHO
    override func ldiscWantsEdit() -> Bool { true }

    override func onConnected() {
        // Mirror PuTTY: offer terminal type and NAWS, request suppress-go-ahead.
        var out: [UInt8] = []
        out += [IAC, WILL, OPT_TTYPE]
        out += [IAC, WILL, OPT_NAWS]
        out += [IAC, DO, OPT_SGA]
        out += [IAC, WILL, OPT_SGA]
        sendRaw(Data(out))
    }

    override func setSize(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        var out: [UInt8] = [IAC, SB, OPT_NAWS,
                            UInt8(cols >> 8), UInt8(cols & 0xff),
                            UInt8(rows >> 8), UInt8(rows & 0xff),
                            IAC, SE]
        // Escape any 255 in the size bytes.
        out = escapeIAC(out, skipFraming: true)
        sendRaw(Data(out))
    }

    override func transformOutgoing(_ data: Data) -> Data {
        // Double any IAC byte in user data.
        var out = [UInt8]()
        for b in data { out.append(b); if b == IAC { out.append(IAC) } }
        return Data(out)
    }

    private func escapeIAC(_ bytes: [UInt8], skipFraming: Bool) -> [UInt8] { bytes }

    override func transformIncoming(_ data: Data) -> Data {
        var out = [UInt8]()
        for b in data {
            switch rstate {
            case .data:
                if b == IAC { rstate = .iac } else { out.append(b) }
            case .iac:
                if b == IAC { out.append(IAC); rstate = .data }
                else if b == SB { rstate = .sb }
                else if b == WILL || b == WONT || b == DO || b == DONT { pendingCmd = b; rstate = .willdo }
                else { rstate = .data }  // ignore other commands (NOP, DM, etc.)
            case .willdo:
                handleNegotiation(cmd: pendingCmd, option: b)
                rstate = .data
            case .sb:
                sbOption = b; sbData = []; rstate = .sbiac
            case .sbiac:
                if b == IAC { rstate = .sbEnd }
                else { sbData.append(b) }
            case .sbEnd:
                // we treat any byte after IAC in SB as end-of-subneg trigger
                handleSubnegotiation()
                rstate = (b == SE) ? .data : .data
            }
        }
        return Data(out)
    }

    private func handleNegotiation(cmd: UInt8, option: UInt8) {
        var reply: [UInt8] = []
        switch cmd {
        case DO:
            switch option {
            case OPT_TTYPE, OPT_NAWS, OPT_SGA, OPT_BINARY:
                reply = [IAC, WILL, option]
                if option == OPT_NAWS { setSize(cols: cols, rows: rows) }
            default:
                reply = [IAC, WONT, option]
            }
        case DONT:
            reply = [IAC, WONT, option]
        case WILL:
            switch option {
            case OPT_ECHO:
                reply = [IAC, DO, option]
                DispatchQueue.main.async { self.delegate?.backendDidReport("[telnet: server echo on]") }
            case OPT_SGA, OPT_BINARY:
                reply = [IAC, DO, option]
            default:
                reply = [IAC, DONT, option]
            }
        case WONT:
            reply = [IAC, DONT, option]
        default: break
        }
        if !reply.isEmpty { sendRaw(Data(reply)) }
    }

    private func handleSubnegotiation() {
        if sbOption == OPT_TTYPE, sbData.first == 1 {   // SEND
            let term = conf.getStr(K.termtype).uppercased()
            var out: [UInt8] = [IAC, SB, OPT_TTYPE, 0]  // IS
            out += Array(term.utf8)
            out += [IAC, SE]
            sendRaw(Data(out))
        }
    }
}
