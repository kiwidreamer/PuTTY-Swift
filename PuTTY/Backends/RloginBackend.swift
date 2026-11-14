import Foundation

/// PROT_RLOGIN — the BSD rlogin protocol (otherbackends/rlogin.c).  On
/// connect it sends the initial NUL-separated handshake of local user,
/// remote user and terminal/speed.
final class RloginBackend: TCPBackend {
    override var name: String { "Rlogin" }
    private let conf: Conf
    private var cols = 80, rows = 24

    init(conf: Conf, host: String, port: Int) {
        self.conf = conf
        super.init(host: host, port: port == 0 ? 513 : port,
                   addressFamily: AddressFamily(rawValue: conf.getInt(K.addressFamily)) ?? .unspec)
    }

    override func ldiscWantsEcho() -> Bool { false }
    override func ldiscWantsEdit() -> Bool { false }

    override func onConnected() {
        let local = conf.getStr(K.localusername).isEmpty
            ? (NSUserName()) : conf.getStr(K.localusername)
        let remote = conf.getStr(K.username).isEmpty ? local : conf.getStr(K.username)
        let term = conf.getStr(K.termtype)
        let speed = conf.getStr(K.termspeed).split(separator: ",").first.map(String.init) ?? "38400"
        var out: [UInt8] = [0]                 // leading NUL
        out += Array(local.utf8); out.append(0)
        out += Array(remote.utf8); out.append(0)
        out += Array("\(term)/\(speed)".utf8); out.append(0)
        sendRaw(Data(out))
    }

    override func transformIncoming(_ data: Data) -> Data {
        // The first byte from the server is a 0 handshake-ack; after that it's
        // a plain stream.  We also handle the 0x80 "window size" control byte
        // request by replying with our size.
        var out = [UInt8]()
        for b in data {
            if b == 0x80 {
                sendWindowSize()
            } else {
                out.append(b)
            }
        }
        return Data(out)
    }

    override func setSize(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
    }

    private func sendWindowSize() {
        var out: [UInt8] = [0xff, 0xff, 0x73, 0x73]   // magic "ss"
        out += [UInt8(rows >> 8), UInt8(rows & 0xff)]
        out += [UInt8(cols >> 8), UInt8(cols & 0xff)]
        out += [0, 0, 0, 0]   // pixel size unknown
        sendRaw(Data(out))
    }
}
