import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // Show the configuration box at startup, as PuTTY does.
        showConfig()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no windows open brings the settings box back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showConfig() }
        return true
    }

    /// Ask once before quitting while sessions are still connected (PuTTY's
    /// "Warn before closing window"), instead of one prompt per window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = TerminalWindowController.openControllers.filter {
            $0.isSessionActive && $0.conf.getBool(K.warnOnClose)
        }
        guard !active.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = active.count == 1
            ? "A session is still open. Quit PuTTY anyway?"
            : "\(active.count) sessions are still open. Quit PuTTY anyway?"
        alert.informativeText = "Quitting closes every connection."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Close every connection (and any ssh helper processes) on the way out.
    func applicationWillTerminate(_ notification: Notification) {
        for c in TerminalWindowController.openControllers { c.shutDown() }
    }

    @objc func showConfig() {
        ConfigWindowController.presentNew()
    }

    @objc func newSession() { showConfig() }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "PuTTY"
        alert.informativeText = """
        Release 0.85 — Swift/Cocoa recreation

        A Telnet, Rlogin, Raw, Serial and SSH client with an xterm-compatible
        terminal.  Settings, defaults and terminal behaviour follow the original
        PuTTY source in this folder.  SSH connections are made through the system
        OpenSSH client.

        PuTTY is copyright 1997–2025 Simon Tatham, under the MIT licence.
        """
        alert.runModal()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About PuTTY", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PuTTY", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit PuTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Session menu
        let sessionItem = NSMenuItem()
        mainMenu.addItem(sessionItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionItem.submenu = sessionMenu
        sessionMenu.addItem(withTitle: "New Session…", action: #selector(newSession), keyEquivalent: "n")

        // Edit menu (for copy/paste in terminal)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(TerminalView.copySelection(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalView.pasteSelection(_:)), keyEquivalent: "v")

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
