import Foundation
import Network

/// Shared TCP plumbing for the Raw/Telnet/Rlogin backends, using Apple's
/// Network framework.  Subclasses override the hooks to transform bytes.
class TCPBackend: Backend {
    weak var delegate: BackendDelegate?
    var name: String { "Raw" }

    let host: String
    let port: Int
    let addressFamily: AddressFamily
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "putty.tcp")

    init(host: String, port: Int, addressFamily: AddressFamily = .unspec) {
        self.host = host
        self.port = port
        self.addressFamily = addressFamily
    }

    func ldiscWantsEdit() -> Bool { false }
    func ldiscWantsEcho() -> Bool { false }

    func start() {
        guard port > 0, !host.isEmpty else {
            delegate?.backendDidClose(clean: false, message: "No host/port specified")
            return
        }
        let params: NWParameters = .tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        switch addressFamily {
        case .ipv4: params.requiredInterfaceType = .other; params.prohibitedInterfaceTypes = []
        default: break
        }
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                     port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let c = NWConnection(to: ep, using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.delegate?.backendDidReport("Connected to \(self.host):\(self.port)")
                    self.delegate?.backendDidConnect()
                    self.onConnected()
                }
                self.receiveLoop()
            case .failed(let err):
                DispatchQueue.main.async {
                    self.delegate?.backendDidClose(clean: false, message: err.localizedDescription)
                }
            case .waiting(let err):
                DispatchQueue.main.async {
                    self.delegate?.backendDidReport("Connecting… (\(err.localizedDescription))")
                }
            case .cancelled:
                DispatchQueue.main.async { self.delegate?.backendDidClose(clean: true, message: nil) }
            default: break
            }
        }
        delegate?.backendDidReport("Looking up host \"\(host)\"")
        c.start(queue: queue)
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                let processed = self.transformIncoming(data)
                if !processed.isEmpty {
                    DispatchQueue.main.async { self.delegate?.backendDidReceive(processed) }
                }
            }
            if let error = error {
                DispatchQueue.main.async { self.delegate?.backendDidClose(clean: false, message: error.localizedDescription) }
                return
            }
            if isComplete {
                DispatchQueue.main.async { self.delegate?.backendDidClose(clean: true, message: nil) }
                return
            }
            self.receiveLoop()
        }
    }

    func send(_ data: Data) {
        let out = transformOutgoing(data)
        conn?.send(content: out, completion: .contentProcessed { _ in })
    }

    func sendRaw(_ data: Data) {
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        conn?.cancel()
        conn = nil
    }

    // Declared here (not only in the protocol extension) so subclasses may override.
    func setSize(cols: Int, rows: Int) {}

    // Hooks for subclasses.
    func onConnected() {}
    func transformIncoming(_ data: Data) -> Data { data }
    func transformOutgoing(_ data: Data) -> Data { data }
}

/// PROT_RAW — a bare TCP byte stream.
final class RawBackend: TCPBackend {
    override var name: String { "Raw" }
}
