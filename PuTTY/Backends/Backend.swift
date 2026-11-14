import Foundation

// The seat/backend boundary, modelled on PuTTY's Backend/Seat split but
// trimmed to what this app needs.  The backend speaks a wire protocol and
// hands received bytes to its delegate; the delegate (the terminal session)
// sends user input back down.

protocol BackendDelegate: AnyObject {
    /// Bytes received from the network/line, to be shown in the terminal.
    func backendDidReceive(_ data: Data)
    /// A human-readable status or error line (shown in the terminal / titlebar).
    func backendDidReport(_ message: String)
    /// The connection finished; `clean` is true for an orderly close.
    func backendDidClose(clean: Bool, message: String?)
    /// Connection established (used to flip local-echo/edit auto decisions).
    func backendDidConnect()
}

protocol Backend: AnyObject {
    var delegate: BackendDelegate? { get set }
    /// Human-readable protocol name, e.g. "SSH".
    var name: String { get }
    /// Whether local line editing should default on for this backend.
    func ldiscWantsEdit() -> Bool
    /// Whether local echo should default on for this backend.
    func ldiscWantsEcho() -> Bool

    func start()
    func send(_ data: Data)
    /// Called when the terminal is resized (cols x rows).
    func setSize(cols: Int, rows: Int)
    func close()
}

extension Backend {
    func send(_ bytes: [UInt8]) { send(Data(bytes)) }
    func setSize(cols: Int, rows: Int) {}
}

// Factory mirroring be_list.c: picks the backend for the configured protocol.
enum BackendFactory {
    static func make(conf: Conf) -> Backend {
        let host = conf.getStr(K.host)
        let port = conf.getInt(K.port)
        switch conf.protocolValue {
        case .raw:    return RawBackend(host: host, port: port)
        case .telnet: return TelnetBackend(conf: conf, host: host, port: port)
        case .rlogin: return RloginBackend(conf: conf, host: host, port: port)
        case .ssh:    return SSHBackend(conf: conf, host: host, port: port)
        case .serial: return SerialBackend(conf: conf)
        case .supdup: return RawBackend(host: host, port: port) // minimal fallback
        }
    }
}
