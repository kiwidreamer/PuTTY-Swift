import AppKit

/// PuTTY's configuration box: a category tree on the left, the selected
/// panel on the right, the host/port/protocol row and saved-session controls
/// on the Session panel, and Open/Cancel (or Apply/Cancel mid-session) below.
final class ConfigWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {

    private let conf: Conf
    private let midSession: Bool
    private var onOpen: ((Conf) -> Void)?

    private var panels: [Panel] = []
    private var tree: [TreeNode] = []
    private var outline: NSOutlineView!
    private var detail: NSView!        // flipped document view holding controls
    private var detailScroll: NSScrollView!
    private var currentPath = "Session"

    // Session panel widgets we keep references to.
    private var hostField: NSTextField?
    private var portField: NSTextField?
    private var sessionList: NSTableView?
    private var sessionNameField: NSTextField?
    private var sessionNames: [String] = []

    // radio button -> conf key, and whether its value is bool
    private var radioKey: [ObjectIdentifier: (key: String, isBool: Bool)] = [:]

    final class TreeNode { let name: String; let path: String; var children: [TreeNode] = []
        init(_ name: String, _ path: String) { self.name = name; self.path = path } }

    init(conf: Conf, midSession: Bool, onOpen: @escaping (Conf) -> Void) {
        self.conf = conf
        self.midSession = midSession
        self.onOpen = onOpen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = midSession ? "PuTTY Reconfiguration" : "PuTTY Configuration"
        super.init(window: window)
        buildUI()
        rebuildPanels()
        selectPath("Session")
    }
    required init?(coder: NSCoder) { fatalError() }

    static func presentNew() {
        let conf = SettingsStore.shared.load("Default Settings") ?? Conf()
        let c = ConfigWindowController(conf: conf, midSession: false) { finalConf in
            let session = TerminalWindowController(conf: finalConf)
            session.startSession()
        }
        NSApp.runModal(for: c.window!)
    }

    static func presentMidSession(conf: Conf, onApply: @escaping (Conf) -> Void) {
        let working = conf.copy()
        let c = ConfigWindowController(conf: working, midSession: true) { finalConf in
            onApply(finalConf)
        }
        NSApp.runModal(for: c.window!)
    }

    // MARK: UI skeleton
    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Category tree.
        let treeScroll = NSScrollView(frame: NSRect(x: 12, y: 54, width: 180, height: 454))
        treeScroll.hasVerticalScroller = true
        treeScroll.autoresizingMask = [.height]
        outline = NSOutlineView(frame: treeScroll.bounds)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cat"))
        col.width = 160
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .default
        treeScroll.documentView = outline
        content.addSubview(treeScroll)

        // Detail area.
        detailScroll = NSScrollView(frame: NSRect(x: 204, y: 54, width: 444, height: 454))
        detailScroll.hasVerticalScroller = true
        detailScroll.autoresizingMask = [.width, .height]
        detailScroll.drawsBackground = false
        detail = FlippedView(frame: NSRect(x: 0, y: 0, width: 428, height: 454))
        detailScroll.documentView = detail
        content.addSubview(detailScroll)

        // Buttons.
        let open = NSButton(title: midSession ? "Apply" : "Open", target: self, action: #selector(openPressed))
        open.frame = NSRect(x: 460, y: 12, width: 90, height: 32)
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.autoresizingMask = [.minXMargin]
        content.addSubview(open)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.frame = NSRect(x: 556, y: 12, width: 90, height: 32)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.autoresizingMask = [.minXMargin]
        content.addSubview(cancel)
    }

    private func rebuildPanels() {
        panels = ConfigPanels.build(conf: conf, midSession: midSession)
        buildTree()
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    private func buildTree() {
        tree = []
        var byPath: [String: TreeNode] = [:]
        for p in panels {
            let comps = p.path.split(separator: "/").map(String.init)
            var accum = ""
            let parentChildren: ([TreeNode]) -> Void = { self.tree.append(contentsOf: $0) }
            var parent: TreeNode? = nil
            for (i, comp) in comps.enumerated() {
                accum = accum.isEmpty ? comp : accum + "/" + comp
                if let existing = byPath[accum] { parent = existing; continue }
                let node = TreeNode(comp, accum)
                byPath[accum] = node
                if let parent = parent { parent.children.append(node) }
                else { tree.append(node) }
                parent = node
                _ = i; _ = parentChildren
            }
        }
    }

    // MARK: Outline data source
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return tree.count }
        return (item as! TreeNode).children.count
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return tree[index] }
        return (item as! TreeNode).children[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(item as! TreeNode).children.isEmpty
    }
    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! TreeNode
        let id = NSUserInterfaceItemIdentifier("cell")
        let tf = (ov.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            return t
        }()
        tf.stringValue = node.name
        return tf
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        if row >= 0, let node = outline.item(atRow: row) as? TreeNode {
            renderPanel(path: node.path)
        }
    }

    private func selectPath(_ path: String) {
        for r in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: r) as? TreeNode, node.path == path {
                outline.selectRowIndexes([r], byExtendingSelection: false)
                renderPanel(path: path)
                return
            }
        }
    }

    // MARK: Panel rendering
    private func renderPanel(path: String) {
        currentPath = path
        guard let panel = panels.first(where: { $0.path == path }) else { return }
        detail.subviews.forEach { $0.removeFromSuperview() }
        radioKey.removeAll()

        let width: CGFloat = 410
        var y: CGFloat = 8
        // Heading
        let heading = NSTextField(labelWithString: panel.title)
        heading.font = .boldSystemFont(ofSize: 12)
        heading.frame = NSRect(x: 8, y: y, width: width, height: 18)
        detail.addSubview(heading)
        y += 26

        for control in panel.controls {
            y = layout(control, atY: y, width: width)
            y += 8
        }

        let totalHeight = max(y + 8, detailScroll.contentSize.height)
        detail.frame = NSRect(x: 0, y: 0, width: detailScroll.contentSize.width, height: totalHeight)
        detail.needsDisplay = true
        detailScroll.documentView?.scroll(NSPoint(x: 0, y: 0))
    }

    private func layout(_ control: Control, atY y0: CGFloat, width: CGFloat) -> CGFloat {
        var y = y0
        switch control {
        case .group(let title, let children):
            let boxX: CGFloat = 8
            let inner = width - 24
            var innerY: CGFloat = title != nil ? 22 : 8
            // temp container; we lay out children into it
            let box = NSBox(frame: NSRect(x: boxX, y: y, width: width, height: 10))
            box.contentView = FlippedView()
            box.titlePosition = title != nil ? .atTop : .noTitle
            if let title = title { box.title = title }
            detail.addSubview(box)
            for child in children {
                innerY = layoutInBox(child, into: box, atY: innerY, width: inner)
                innerY += 6
            }
            box.frame = NSRect(x: boxX, y: y, width: width, height: innerY + 8)
            y += innerY + 8
        default:
            // Non-grouped control laid straight into detail
            let dummy = NSBox()
            _ = dummy
            y = layoutBare(control, atY: y, width: width)
        }
        return y
    }

    private func layoutBare(_ control: Control, atY y0: CGFloat, width: CGFloat) -> CGFloat {
        let box = NSBox(frame: NSRect(x: 8, y: y0, width: width, height: 10))
        box.contentView = FlippedView()
        box.titlePosition = .noTitle
        detail.addSubview(box)
        let h = layoutInBox(control, into: box, atY: 8, width: width - 16)
        box.frame = NSRect(x: 8, y: y0, width: width, height: h + 8)
        return y0 + h + 8
    }

    private func layoutInBox(_ control: Control, into box: NSBox, atY y0: CGFloat, width: CGFloat) -> CGFloat {
        var y = y0
        let x: CGFloat = 10
        switch control {
        case .checkbox(let label, let key):
            let b = NSButton(checkboxWithTitle: label, target: self, action: #selector(checkToggled(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.state = conf.getBool(key) ? .on : .off
            b.frame = NSRect(x: x, y: y, width: width - 20, height: 18)
            box.contentView?.addSubview(b)
            y += 22
        case .checkboxInverted(let label, let key):
            let b = NSButton(checkboxWithTitle: label, target: self, action: #selector(checkToggledInverted(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.state = conf.getBool(key) ? .off : .on
            b.frame = NSRect(x: x, y: y, width: width - 20, height: 18)
            box.contentView?.addSubview(b)
            y += 22
        case .editbox(let label, let key, let kind):
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: x, y: y + 2, width: width - 110, height: 18)
            box.contentView?.addSubview(l)
            let f = NSTextField(frame: NSRect(x: width - 96, y: y, width: 86, height: 22))
            f.identifier = NSUserInterfaceItemIdentifier(key)
            f.stringValue = kind == .int ? String(conf.getInt(key)) : conf.getStr(key)
            f.delegate = self
            f.target = self
            f.action = #selector(textCommitted(_:))
            box.contentView?.addSubview(f)
            objc_setAssociatedObject(f, &editKindKey, kind == .int ? 1 : 0, .OBJC_ASSOCIATION_RETAIN)
            y += 26
        case .radio(let label, let key, let cols, let options):
            y = layoutRadio(label: label, key: key, isBool: false, cols: cols,
                            options: options.map { ($0.0, $0.1) }, box: box, y: y, width: width)
        case .radioBool(let label, let key, let options):
            y = layoutRadio(label: label, key: key, isBool: true, cols: options.count,
                            options: options.map { ($0.0, $0.1 ? 1 : 0) }, box: box, y: y, width: width)
        case .droplist(let label, let key, let options):
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: x, y: y + 2, width: width - 160, height: 18)
            box.contentView?.addSubview(l)
            let pop = NSPopUpButton(frame: NSRect(x: width - 150, y: y, width: 140, height: 24))
            for o in options { pop.addItem(withTitle: o.0); pop.lastItem?.tag = o.1 }
            pop.selectItem(withTag: conf.getInt(key))
            pop.identifier = NSUserInterfaceItemIdentifier(key)
            pop.target = self; pop.action = #selector(dropChanged(_:))
            box.contentView?.addSubview(pop)
            y += 28
        case .text(let s):
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 10)
            l.frame = NSRect(x: x, y: y, width: width - 20, height: 30)
            box.contentView?.addSubview(l)
            y += 34
        case .font(let label, let key):
            let l = NSTextField(labelWithString: "\(label): \(conf.getStr(key))")
            l.frame = NSRect(x: x, y: y + 4, width: width - 100, height: 18)
            l.identifier = NSUserInterfaceItemIdentifier("fontlabel:" + key)
            box.contentView?.addSubview(l)
            let b = NSButton(title: "Change…", target: self, action: #selector(chooseFont(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: width - 90, y: y, width: 80, height: 24)
            box.contentView?.addSubview(b)
            y += 28
        case .fileField(let label, let key):
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: x, y: y + 2, width: width - 20, height: 18)
            box.contentView?.addSubview(l)
            y += 22
            let f = NSTextField(frame: NSRect(x: x, y: y, width: width - 100, height: 22))
            f.identifier = NSUserInterfaceItemIdentifier(key)
            f.stringValue = conf.getStr(key)
            f.target = self; f.action = #selector(textCommitted(_:))
            box.contentView?.addSubview(f)
            let b = NSButton(title: "Browse…", target: self, action: #selector(browseFile(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: width - 86, y: y, width: 76, height: 24)
            box.contentView?.addSubview(b)
            objc_setAssociatedObject(b, &fileFieldKey, f, .OBJC_ASSOCIATION_RETAIN)
            y += 28
        case .colours:
            y = layoutColours(box: box, y: y, width: width)
        case .custom(let id):
            y = layoutCustom(id, box: box, y: y, width: width)
        case .group:
            break  // groups aren't nested in this port
        }
        return y
    }

    private func layoutRadio(label: String?, key: String, isBool: Bool, cols: Int,
                             options: [(String, Int)], box: NSBox, y y0: CGFloat, width: CGFloat) -> CGFloat {
        var y = y0
        let x: CGFloat = 10
        if let label = label {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: x, y: y, width: width - 20, height: 18)
            box.contentView?.addSubview(l)
            y += 22
        }
        let colW = (width - 20) / CGFloat(max(1, cols))
        var i = 0
        let current = conf.getInt(key)
        for (titleStr, value) in options {
            let colIndex = i % cols
            let rowIndex = i / cols
            let b = NSButton(radioButtonWithTitle: titleStr, target: self, action: #selector(radioChanged(_:)))
            b.tag = value
            b.state = (value == current) ? .on : .off
            b.frame = NSRect(x: x + CGFloat(colIndex) * colW, y: y + CGFloat(rowIndex) * 22,
                             width: colW - 4, height: 18)
            radioKey[ObjectIdentifier(b)] = (key, isBool)
            box.contentView?.addSubview(b)
            i += 1
        }
        let rows = (options.count + cols - 1) / cols
        y += CGFloat(rows) * 22
        return y
    }

    // MARK: custom Session controls
    private func layoutCustom(_ id: String, box: NSBox, y y0: CGFloat, width: CGFloat) -> CGFloat {
        var y = y0
        let x: CGFloat = 10
        switch id {
        case "hostport":
            let hl = NSTextField(labelWithString: "Host Name (or IP address)")
            hl.frame = NSRect(x: x, y: y, width: width - 90, height: 18)
            box.contentView?.addSubview(hl)
            let pl = NSTextField(labelWithString: "Port")
            pl.frame = NSRect(x: width - 70, y: y, width: 60, height: 18)
            box.contentView?.addSubview(pl)
            y += 20
            let hf = NSTextField(frame: NSRect(x: x, y: y, width: width - 90, height: 22))
            hf.stringValue = conf.getStr(K.host)
            hf.target = self; hf.action = #selector(hostCommitted(_:))
            hf.delegate = self
            box.contentView?.addSubview(hf); hostField = hf
            let pf = NSTextField(frame: NSRect(x: width - 70, y: y, width: 60, height: 22))
            pf.stringValue = String(conf.getInt(K.port))
            pf.target = self; pf.action = #selector(portCommitted(_:))
            pf.delegate = self
            box.contentView?.addSubview(pf); portField = pf
            y += 30
        case "protocol":
            let l = NSTextField(labelWithString: "Connection type:")
            l.frame = NSRect(x: x, y: y, width: width - 20, height: 18)
            box.contentView?.addSubview(l)
            y += 22
            var i = 0
            let allButtons = PuttyProtocol.radioProtocols
            let current = conf.protocolValue
            let colW = (width - 20) / CGFloat(allButtons.count + 1)
            for p in allButtons {
                let b = NSButton(radioButtonWithTitle: p.displayName, target: self, action: #selector(protocolChanged(_:)))
                b.tag = p.rawValue
                b.state = (p == current) ? .on : .off
                b.frame = NSRect(x: x + CGFloat(i) * colW, y: y, width: colW - 4, height: 18)
                box.contentView?.addSubview(b)
                i += 1
            }
            // "Other" droplist
            let other = NSButton(radioButtonWithTitle: "Other:", target: self, action: #selector(protocolOtherChosen(_:)))
            other.frame = NSRect(x: x + CGFloat(i) * colW, y: y, width: 60, height: 18)
            other.state = PuttyProtocol.otherProtocols.contains(current) ? .on : .off
            box.contentView?.addSubview(other)
            let pop = NSPopUpButton(frame: NSRect(x: x + CGFloat(i) * colW + 62, y: y - 2, width: 110, height: 24))
            for p in PuttyProtocol.otherProtocols { pop.addItem(withTitle: p.displayName); pop.lastItem?.tag = p.rawValue }
            if PuttyProtocol.otherProtocols.contains(current) { pop.selectItem(withTag: current.rawValue) }
            pop.target = self; pop.action = #selector(protocolOtherPicked(_:))
            box.contentView?.addSubview(pop)
            y += 28
        case "sessions":
            let l = NSTextField(labelWithString: "Saved Sessions")
            l.frame = NSRect(x: x, y: y, width: width - 20, height: 18)
            box.contentView?.addSubview(l)
            y += 20
            let nameField = NSTextField(frame: NSRect(x: x, y: y, width: width - 20, height: 22))
            box.contentView?.addSubview(nameField); sessionNameField = nameField
            y += 28
            let listScroll = NSScrollView(frame: NSRect(x: x, y: y, width: width - 110, height: 120))
            listScroll.hasVerticalScroller = true
            listScroll.borderType = .bezelBorder
            let table = NSTableView(frame: listScroll.bounds)
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("s"))
            c.width = width - 130
            table.addTableColumn(c); table.headerView = nil
            table.dataSource = self as? NSTableViewDataSource
            table.delegate = self as? NSTableViewDelegate
            table.target = self; table.doubleAction = #selector(loadDoubleClicked)
            listScroll.documentView = table
            box.contentView?.addSubview(listScroll); sessionList = table
            sessionNames = ["Default Settings"] + SettingsStore.shared.sessionList().filter { $0 != "Default Settings" }

            let bx = width - 95
            let loadB = NSButton(title: "Load", target: self, action: #selector(loadSession)); loadB.bezelStyle = .rounded
            loadB.frame = NSRect(x: bx, y: y + 2, width: 85, height: 26); box.contentView?.addSubview(loadB)
            let saveB = NSButton(title: "Save", target: self, action: #selector(saveSession)); saveB.bezelStyle = .rounded
            saveB.frame = NSRect(x: bx, y: y + 32, width: 85, height: 26); box.contentView?.addSubview(saveB)
            let delB = NSButton(title: "Delete", target: self, action: #selector(deleteSession)); delB.bezelStyle = .rounded
            delB.frame = NSRect(x: bx, y: y + 62, width: 85, height: 26); box.contentView?.addSubview(delB)
            table.reloadData()
            y += 128
        default: break
        }
        return y
    }

    // MARK: Colours editor (simplified: shows the default fg/bg swatches editable)
    private var colourWells: [NSColorWell] = []
    private func layoutColours(box: NSBox, y y0: CGFloat, width: CGFloat) -> CGFloat {
        var y = y0
        colourWells = []
        let names = ["Default Foreground", "Default Background", "Cursor Colour",
                     "ANSI Red", "ANSI Green", "ANSI Blue"]
        let slots = [TerminalPalette.Named.fg, .bg, .cursorBg, .red, .green, .blue].map { $0.rawValue }
        let pal = TerminalPalette(conf: conf)
        for (i, name) in names.enumerated() {
            let l = NSTextField(labelWithString: name)
            l.frame = NSRect(x: 10, y: y + 2, width: width - 80, height: 18)
            box.contentView?.addSubview(l)
            let well = NSColorWell(frame: NSRect(x: width - 60, y: y, width: 50, height: 22))
            well.color = pal.nsColor(slots[i])
            well.tag = slots[i]
            well.target = self; well.action = #selector(colourChanged(_:))
            box.contentView?.addSubview(well)
            colourWells.append(well)
            y += 26
        }
        return y
    }

    // MARK: actions
    @objc private func checkToggled(_ sender: NSButton) {
        if let k = sender.identifier?.rawValue { conf.set(k, sender.state == .on) }
    }
    @objc private func checkToggledInverted(_ sender: NSButton) {
        if let k = sender.identifier?.rawValue { conf.set(k, sender.state == .off) }
    }
    @objc private func radioChanged(_ sender: NSButton) {
        guard let info = radioKey[ObjectIdentifier(sender)] else { return }
        // Deselect siblings sharing the same key.
        for (oid, i2) in radioKey where i2.key == info.key {
            if let b = objcButton(oid) { b.state = (b === sender) ? .on : .off }
        }
        if info.isBool { conf.set(info.key, sender.tag != 0) }
        else { conf.set(info.key, sender.tag) }
    }
    private func objcButton(_ oid: ObjectIdentifier) -> NSButton? {
        for v in allSubviews(detail) where v is NSButton {
            if ObjectIdentifier(v) == oid { return v as? NSButton }
        }
        return nil
    }
    private func allSubviews(_ v: NSView) -> [NSView] {
        var out = [NSView]()
        for s in v.subviews { out.append(s); out.append(contentsOf: allSubviews(s)) }
        return out
    }
    @objc private func dropChanged(_ sender: NSPopUpButton) {
        if let k = sender.identifier?.rawValue { conf.set(k, sender.selectedTag()) }
    }
    @objc private func textCommitted(_ sender: NSTextField) {
        commitText(sender)
    }
    private func commitText(_ sender: NSTextField) {
        guard let k = sender.identifier?.rawValue else { return }
        let isInt = (objc_getAssociatedObject(sender, &editKindKey) as? Int) == 1
        if isInt { conf.set(k, Int(sender.stringValue) ?? conf.getInt(k)) }
        else { conf.set(k, sender.stringValue) }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        if tf === hostField { conf.set(K.host, tf.stringValue) }
        else if tf === portField { conf.set(K.port, Int(tf.stringValue) ?? conf.getInt(K.port)) }
        else if tf.identifier != nil { commitText(tf) }
    }

    @objc private func hostCommitted(_ sender: NSTextField) { conf.set(K.host, sender.stringValue) }
    @objc private func portCommitted(_ sender: NSTextField) { conf.set(K.port, Int(sender.stringValue) ?? conf.getInt(K.port)) }

    @objc private func protocolChanged(_ sender: NSButton) {
        guard let p = PuttyProtocol(rawValue: sender.tag) else { return }
        switchProtocol(p)
    }
    @objc private func protocolOtherChosen(_ sender: NSButton) {
        switchProtocol(.raw)
    }
    @objc private func protocolOtherPicked(_ sender: NSPopUpButton) {
        if let p = PuttyProtocol(rawValue: sender.selectedTag()) { switchProtocol(p) }
    }
    private func switchProtocol(_ p: PuttyProtocol) {
        let old = conf.protocolValue
        conf.protocolValue = p
        // Update default port if it was the old protocol's default (config.c behaviour).
        if conf.getInt(K.port) == old.defaultPort || conf.getInt(K.port) == 0 {
            if p.defaultPort > 0 { conf.set(K.port, p.defaultPort) }
        }
        rebuildPanels()
        selectPath("Session")
    }

    @objc private func chooseFont(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let (f, _) = TerminalView.resolveFonts(conf.getStr(key))
        fontTargetKey = key
        NSFontManager.shared.setSelectedFont(f, isMultiple: false)
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(fontPicked(_:))
        NSFontPanel.shared.makeKeyAndOrderFront(nil)
    }
    private var fontTargetKey: String?
    @objc private func fontPicked(_ sender: Any?) {
        guard let key = fontTargetKey else { return }
        let f = NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        conf.set(key, "\(f.fontName) \(Int(f.pointSize))")
        renderPanel(path: currentPath)
    }

    @objc private func browseFile(_ sender: NSButton) {
        guard let field = objc_getAssociatedObject(sender, &fileFieldKey) as? NSTextField,
              let key = sender.identifier?.rawValue else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url {
            field.stringValue = url.path
            conf.set(key, url.path)
        }
    }

    @objc private func colourChanged(_ sender: NSColorWell) {
        // Stored as "r,g,b" lists in PuTTY; here we keep the live palette simple
        // by writing into the Conf colour slots via dedicated keys.
        let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
        let key = "Colour\(sender.tag)"
        conf.set(key, String(format: "%d,%d,%d",
                             Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255)))
    }

    // MARK: session buttons
    @objc private func loadDoubleClicked() { loadSession(); openPressed() }
    @objc private func loadSession() {
        guard let table = sessionList, table.selectedRow >= 0 else { return }
        let name = sessionNames[table.selectedRow]
        if let loaded = (name == "Default Settings" ? (SettingsStore.shared.load(name) ?? Conf()) : SettingsStore.shared.load(name)) {
            conf.replaceAll(from: loaded)
            sessionNameField?.stringValue = name == "Default Settings" ? "" : name
            rebuildPanels(); selectPath("Session")
        }
    }
    @objc private func saveSession() {
        let name = sessionNameField?.stringValue.isEmpty == false ? sessionNameField!.stringValue : "Default Settings"
        SettingsStore.shared.save(conf, as: name)
        sessionNames = ["Default Settings"] + SettingsStore.shared.sessionList().filter { $0 != "Default Settings" }
        sessionList?.reloadData()
    }
    @objc private func deleteSession() {
        guard let table = sessionList, table.selectedRow >= 0 else { return }
        let name = sessionNames[table.selectedRow]
        guard name != "Default Settings" else { return }
        SettingsStore.shared.delete(name)
        sessionNames = ["Default Settings"] + SettingsStore.shared.sessionList().filter { $0 != "Default Settings" }
        sessionList?.reloadData()
    }

    @objc private func openPressed() {
        onOpen?(conf)
        close()
    }

    @objc private func cancelPressed() {
        close()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private var editKindKey: UInt8 = 0
private var fileFieldKey: UInt8 = 0
