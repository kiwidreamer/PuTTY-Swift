import Foundation
import Darwin

/// PROT_SSH.  A from-scratch SSH-2 transport is far too large (and risky) to
/// reimplement here, so this backend drives the operating system's own,
/// audited OpenSSH client under a pseudo-terminal.  The configuration window's
/// SSH options are translated into ssh(1) command-line arguments.  All session
/// bytes flow through PuTTY's own terminal emulator and UI, exactly as the
/// original does with its internal transport.
final class SSHBackend: Backend {
    weak var delegate: BackendDelegate?
    var name: String { "SSH" }

    private let conf: Conf
    private let host: String
    private let port: Int
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var source: DispatchSourceRead?
    private var cols = 80, rows = 24

    init(conf: Conf, host: String, port: Int) {
        self.conf = conf
        self.host = host
        self.port = port == 0 ? 22 : port
    }

    func ldiscWantsEdit() -> Bool { false }   // SSH does its own echo/edit
    func ldiscWantsEcho() -> Bool { false }

    private func sshArguments() -> [String] {
        var args = ["ssh"]
        args += ["-p", String(port)]
        // Force a PTY so interactive prompts and full-screen apps work.
        args += ["-t", "-t"]
        if conf.getBool(K.compression) { args.append("-C") }
        if conf.getInt(K.sshprot) == 0 { args += ["-1"] } else { args += ["-2"] }
        switch AddressFamily(rawValue: conf.getInt(K.addressFamily)) ?? .unspec {
        case .ipv4: args.append("-4")
        case .ipv6: args.append("-6")
        case .unspec: break
        }
        let keyfile = conf.getStr(K.keyfile)
        if !keyfile.isEmpty { args += ["-i", keyfile] }
        if conf.getBool(K.agentfwd) { args.append("-A") }
        if conf.getBool(K.x11Forward) { args.append("-X") }
        if conf.getBool(K.nopty) { args.append("-T") }
        // Keepalives.
        let ka = conf.getInt(K.pingInterval)
        if ka > 0 { args += ["-o", "ServerAliveInterval=\(ka)"] }
        if conf.getBool(K.tcpNoDelay) == false { args += ["-o", "IPQoS=throughput"] }
        // Local port forwardings could be added here from CONF_portfwd.
        let user = conf.getStr(K.username)
        let target = user.isEmpty ? host : "\(user)@\(host)"
        args.append(target)
        let remoteCmd = conf.getStr(K.remoteCmd)
        if !remoteCmd.isEmpty { args.append(remoteCmd) }
        return args
    }

    func start() {
        guard !host.isEmpty else {
            delegate?.backendDidClose(clean: false, message: "No hostname specified")
            return
        }
        let sshPath = "/usr/bin/ssh"
        let args = sshArguments()
        delegate?.backendDidReport("Connecting to \(host) port \(port) via ssh…")

        // Build C argv.
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        var master: Int32 = -1
        var pid: pid_t = -1
        let rc = sshPath.withCString { pathPtr in
            pty_spawn(pathPtr, &cargs, Int32(cols), Int32(rows), &master, &pid)
        }
        for p in cargs where p != nil { free(p) }
        if rc != 0 {
            delegate?.backendDidClose(clean: false, message: "Could not start ssh")
            return
        }
        masterFD = master
        childPID = pid
        delegate?.backendDidConnect()
        startReading()
    }

    private func startReading() {
        let fd = masterFD
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global())
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                DispatchQueue.main.async { self.delegate?.backendDidReceive(data) }
            } else {
                self.source?.cancel()
                DispatchQueue.main.async { self.reap() }
            }
        }
        src.setCancelHandler { [fd] in Darwin.close(fd) }
        source = src
        src.resume()
    }

    private func reap() {
        var status: Int32 = 0
        if childPID > 0 { waitpid(childPID, &status, WNOHANG) }
        let clean = (status == 0)
        delegate?.backendDidClose(clean: clean, message: clean ? nil : "ssh exited")
    }

    func send(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            var p = raw.bindMemory(to: UInt8.self).baseAddress!
            var remaining = data.count
            while remaining > 0 {
                let n = write(masterFD, p, remaining)
                if n <= 0 { break }
                p = p.advanced(by: n); remaining -= n
            }
        }
    }

    func setSize(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        if masterFD >= 0 { pty_set_winsize(masterFD, Int32(cols), Int32(rows)) }
    }

    func close() {
        source?.cancel()
        if childPID > 0 { kill(childPID, SIGHUP) }
        masterFD = -1
    }
}
