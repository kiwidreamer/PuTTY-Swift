import AppKit

/// Hosts one terminal session: the emulator, the backend, the line discipline
/// and the view, plus the right-click menu PuTTY shows.
final class TerminalWindowController: NSWindowController,
    TerminalEmulatorDelegate, BackendDelegate, TerminalViewInput, NSWindowDelegate {

    let conf: Conf
    private let emulator: TerminalEmulator
    private var backend: Backend!
    private var ldisc: Ldisc!
    private let termView: TerminalView
    private let scrollView: NSView
    private var closedCleanly = false
    private var connected = false

    static var openControllers: [TerminalWindowController] = []

    init(conf: Conf) {
        self.conf = conf
        let cols = conf.getInt(K.width), rows = conf.getInt(K.height)
        self.emulator = TerminalEmulator(cols: cols, rows: rows,
                                         scrollback: conf.getInt(K.savelines))
        self.emulator.wrapMode = conf.getBool(K.wrapMode)
        self.emulator.bce = conf.getBool(K.bce)
        self.emulator.answerback = conf.getStr(K.answerback)
        self.emulator.utf8 = conf.getStr(K.lineCodepage).uppercased().contains("UTF-8")
        self.termView = TerminalView(term: emulator, conf: conf)
        self.scrollView = NSView()

        let size = termView.terminalSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Self.initialTitle(conf)
        super.init(window: window)

        window.delegate = self
        emulator.delegate = self
        termView.input = self
        termView.autoresizingMask = [.width, .height]
        window.contentView = termView
        window.setContentSize(size)
        window.center()

        // Build the backend and line discipline.
        backend = BackendFactory.make(conf: conf)
        backend.delegate = self
        ldisc = Ldisc(conf: conf, backend: backend) { [weak self] data in
            self?.emulator.feed(data)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func initialTitle(_ conf: Conf) -> String {
        let t = conf.getStr(K.wintitle)
        if !t.isEmpty { return t }
        let host = conf.getStr(K.host)
        if conf.protocolValue == .serial { return "\(conf.getStr(K.serline)) - PuTTY" }
        return host.isEmpty ? "PuTTY" : "\(host) - PuTTY"
    }

    func startSession() {
        Self.openControllers.append(self)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(termView)
        backend.setSize(cols: emulator.cols, rows: emulator.rows)
        backend.start()
    }

    // MARK: TerminalEmulatorDelegate
    func terminalSend(_ data: Data) { backend.send(data) }
    func terminalBell() {
        switch BellType(rawValue: conf.getInt(K.beep)) ?? .def {
        case .disabled: break
        case .def: NSSound.beep()
        case .visual: flashWindow()
        }
    }
    func terminalSetTitle(_ title: String) {
        if !conf.getBool(K.noRemoteWintitle) { window?.title = title }
    }
    func terminalNeedsRedraw() { termView.refresh() }

    private func flashWindow() {
        guard let v = window?.contentView else { return }
        v.layer?.backgroundColor = NSColor.white.cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            v.layer?.backgroundColor = self.termView.palette.nsColor(TerminalPalette.Named.bg.rawValue).cgColor
        }
    }

    // MARK: BackendDelegate
    func backendDidReceive(_ data: Data) { emulator.feed(data) }
    func backendDidReport(_ message: String) {
        emulator.feed(Data(("\r\n" + message + "\r\n").utf8))
    }
    func backendDidConnect() {
        connected = true
        ldisc.recompute()
    }
    func backendDidClose(clean: Bool, message: String?) {
        closedCleanly = clean
        if let message = message {
            emulator.feed(Data(("\r\n" + message + "\r\n").utf8))
        }
        let policy = CloseOnExit(rawValue: conf.getInt(K.closeOnExit)) ?? .cleanOnly
        let shouldClose = (policy == .always) || (policy == .cleanOnly && clean)
        if shouldClose {
            DispatchQueue.main.async { self.window?.close() }
        } else {
            emulator.feed(Data("\r\n[Session closed - press any key is not required; use the menu to restart]\r\n".utf8))
        }
    }

    // MARK: TerminalViewInput
    func terminalViewSend(_ bytes: [UInt8]) {
        if conf.protocolValue == .ssh {
            backend.send(Data(bytes))   // SSH handles its own echo/edit
        } else {
            ldisc.send(bytes, interactive: true)
        }
    }
    func terminalViewPaste(_ text: String) {
        let data = Data(text.replacingOccurrences(of: "\n", with: "\r").utf8)
        if conf.protocolValue == .ssh { backend.send(data) }
        else { ldisc.send(Array(data), interactive: false) }
    }
    func terminalViewContextMenu(_ event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Restart Session", action: #selector(restartSession), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Duplicate Session", action: #selector(duplicateSession), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Change Settings…", action: #selector(changeSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Scrollback", action: #selector(clearScrollback), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset Terminal", action: #selector(resetTerminal), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let copy = menu.addItem(withTitle: "Copy", action: #selector(TerminalView.copySelection(_:)), keyEquivalent: "")
        copy.target = termView
        let paste = menu.addItem(withTitle: "Paste", action: #selector(TerminalView.pasteSelection(_:)), keyEquivalent: "")
        paste.target = termView
        let all = menu.addItem(withTitle: "Copy All", action: #selector(TerminalView.copyAll(_:)), keyEquivalent: "")
        all.target = termView
        menu.addItem(.separator())
        menu.addItem(withTitle: "About PuTTY", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        return menu
    }

    @objc private func restartSession() {
        backend.close()
        emulator.reset(hard: true)
        backend = BackendFactory.make(conf: conf)
        backend.delegate = self
        ldisc = Ldisc(conf: conf, backend: backend) { [weak self] d in self?.emulator.feed(d) }
        backend.setSize(cols: emulator.cols, rows: emulator.rows)
        backend.start()
    }
    @objc private func duplicateSession() {
        let c = TerminalWindowController(conf: conf.copy())
        c.startSession()
    }
    @objc private func changeSettings() {
        ConfigWindowController.presentMidSession(conf: conf, parent: window) { [weak self] newConf in
            guard let self = self else { return }
            // Apply the live-reconfigurable bits.
            self.conf.merge(from: newConf)
            self.termView.reloadFontAndPalette()
            self.emulator.wrapMode = self.conf.getBool(K.wrapMode)
            self.ldisc.recompute()
            self.termView.needsDisplay = true
        }
    }
    @objc private func clearScrollback() { emulator.reset(hard: false); termView.needsDisplay = true }
    @objc private func resetTerminal() { emulator.reset(hard: true); termView.needsDisplay = true }

    // MARK: window sizing -> backend resize
    func windowDidResize(_ notification: Notification) {
        let cell = termView.charCell
        guard cell.width > 0, cell.height > 0 else { return }
        let inset = CGFloat(conf.getInt(K.windowBorder)) * 2
        let cols = max(1, Int((termView.bounds.width - inset) / cell.width))
        let rows = max(1, Int((termView.bounds.height - inset) / cell.height))
        if cols != emulator.cols || rows != emulator.rows {
            emulator.resize(cols: cols, rows: rows)
            backend.setSize(cols: cols, rows: rows)
            termView.needsDisplay = true
        }
    }

    func windowWillClose(_ notification: Notification) {
        backend.close()
        Self.openControllers.removeAll { $0 === self }
    }

    /// True while the connection is up (used to warn before quitting).
    var isSessionActive: Bool { connected && !closedCleanly }

    /// Shut the connection down without asking (used when the app quits).
    func shutDown() { backend.close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if connected && !closedCleanly && conf.getBool(K.warnOnClose) {
            let alert = NSAlert()
            alert.messageText = "Are you sure you want to close this session?"
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }
}
