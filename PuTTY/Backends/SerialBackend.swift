import Foundation
import Darwin

/// PROT_SERIAL — a local serial line (unix/serial.c).  Opens the device with
/// POSIX termios configured for the chosen speed, data bits, stop bits, parity
/// and flow control, and streams bytes both ways.
final class SerialBackend: Backend {
    weak var delegate: BackendDelegate?
    var name: String { "Serial" }

    private let conf: Conf
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init(conf: Conf) { self.conf = conf }

    func ldiscWantsEdit() -> Bool { true }
    func ldiscWantsEcho() -> Bool { true }

    func start() {
        let path = conf.getStr(K.serline)
        guard !path.isEmpty else {
            delegate?.backendDidClose(clean: false, message: "No serial line configured")
            return
        }
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 {
            delegate?.backendDidClose(clean: false, message: "Unable to open \(path): \(String(cString: strerror(errno)))")
            return
        }
        // Back to blocking for reads via dispatch source.
        _ = fcntl(fd, F_SETFL, 0)
        configure()
        delegate?.backendDidReport("Opened \(path) at \(conf.getInt(K.serspeed)) baud")
        delegate?.backendDidConnect()
        startReading()
    }

    private func configure() {
        var tio = termios()
        tcgetattr(fd, &tio)
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)

        // Baud.
        let speed = speedConstant(conf.getInt(K.serspeed))
        cfsetispeed(&tio, speed)
        cfsetospeed(&tio, speed)

        // Data bits.
        tio.c_cflag &= ~tcflag_t(CSIZE)
        switch conf.getInt(K.serdatabits) {
        case 5: tio.c_cflag |= tcflag_t(CS5)
        case 6: tio.c_cflag |= tcflag_t(CS6)
        case 7: tio.c_cflag |= tcflag_t(CS7)
        default: tio.c_cflag |= tcflag_t(CS8)
        }

        // Stop bits (stored in half-bits: 2 = 1 stop bit, 4 = 2 stop bits).
        if conf.getInt(K.serstopbits) >= 4 { tio.c_cflag |= tcflag_t(CSTOPB) }
        else { tio.c_cflag &= ~tcflag_t(CSTOPB) }

        // Parity.
        switch SerParity(rawValue: conf.getInt(K.serparity)) ?? .none {
        case .none: tio.c_cflag &= ~tcflag_t(PARENB)
        case .odd:  tio.c_cflag |= tcflag_t(PARENB | PARODD)
        case .even: tio.c_cflag |= tcflag_t(PARENB); tio.c_cflag &= ~tcflag_t(PARODD)
        case .mark, .space: tio.c_cflag |= tcflag_t(PARENB)  // best effort
        }

        // Flow control.
        switch SerFlow(rawValue: conf.getInt(K.serflow)) ?? .none {
        case .xonxoff: tio.c_iflag |= tcflag_t(IXON | IXOFF)
        case .rtscts:  tio.c_cflag |= tcflag_t(CRTSCTS)
        default: break
        }

        tcsetattr(fd, TCSANOW, &tio)
    }

    private func speedConstant(_ baud: Int) -> speed_t {
        let map: [Int: Int32] = [
            300: B300, 1200: B1200, 2400: B2400, 4800: B4800, 9600: B9600,
            19200: B19200, 38400: B38400, 57600: B57600, 115200: B115200, 230400: B230400
        ]
        return speed_t(map[baud] ?? B9600)
    }

    private func startReading() {
        let f = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: DispatchQueue.global())
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(f, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                DispatchQueue.main.async { self.delegate?.backendDidReceive(data) }
            } else if n == 0 {
                self.source?.cancel()
                DispatchQueue.main.async { self.delegate?.backendDidClose(clean: true, message: nil) }
            }
        }
        src.setCancelHandler { [f] in Darwin.close(f) }
        source = src
        src.resume()
    }

    func send(_ data: Data) {
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, data.count)
        }
    }

    func setSize(cols: Int, rows: Int) {}

    func close() {
        source?.cancel()
        fd = -1
    }
}
