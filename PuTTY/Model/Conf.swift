import Foundation

// A direct port of PuTTY's configuration model (conf.h / settings.c).
// Each option has a stable key, a value type, and the same default value
// PuTTY ships with. The keys used for on-disk storage match PuTTY's
// "save keyword" names so saved sessions look familiar.

// Tri-state used across PuTTY for many options.
enum TriState: Int { case forceOn = 0, forceOff = 1, auto = 2 }

// Values match PuTTY's enum ordering where the UI depends on it.
enum CloseOnExit: Int { case always = 0, never = 1, cleanOnly = 2 }      // FORCE_ON/OFF/AUTO
enum CursorType: Int { case block = 0, underline = 1, verticalLine = 2 }
enum BellType: Int { case disabled = 0, def = 1, visual = 2 }            // BELL_DISABLED/DEFAULT/VISUAL
enum FunkyType: Int { case tilde = 0, linux = 1, xterm = 2, vt400 = 3, vt100p = 4, sco = 5, xterm216 = 6 }
enum ShArrowType: Int { case application = 0, bitmap = 1 }
enum BoldStyle: Int { case font = 1, colour = 2, both = 3 }
enum VTMode: Int { case unicode = 0, poorman = 5 }                       // VT_UNICODE / VT_POORMAN
enum AddressFamily: Int { case unspec = 0, ipv4 = 1, ipv6 = 2 }
enum LogType: Int { case none = 0, ascii = 1, debug = 2, packets = 3, sshraw = 4 }
enum LogClash: Int { case overwrite = 0, append = 1, ask = 2 }

// Serial
enum SerParity: Int { case none = 0, odd, even, mark, space }
enum SerFlow: Int { case none = 0, xonxoff, rtscts, dsrdtr }

/// The complete set of configuration options.  Backed by a dictionary so
/// panels can read/write generically, but exposed through typed helpers.
final class Conf {
    enum Value: Equatable {
        case int(Int)
        case bool(Bool)
        case string(String)
    }

    private(set) var values: [String: Value] = [:]

    init() { loadDefaults() }

    func copy() -> Conf {
        let c = Conf()
        c.values = values
        return c
    }

    /// Replace every value with those of another configuration.
    func replaceAll(from other: Conf) { values = other.values }
    /// Merge another configuration in, preferring its values.
    func merge(from other: Conf) { values.merge(other.values) { _, new in new } }

    // MARK: generic access
    func getInt(_ k: String) -> Int { if case .int(let v)? = values[k] { return v }; if case .bool(let b)? = values[k] { return b ? 1 : 0 }; return 0 }
    func getBool(_ k: String) -> Bool { if case .bool(let v)? = values[k] { return v }; if case .int(let i)? = values[k] { return i != 0 }; return false }
    func getStr(_ k: String) -> String { if case .string(let v)? = values[k] { return v }; return "" }

    func set(_ k: String, _ v: Int) { values[k] = .int(v) }
    func set(_ k: String, _ v: Bool) { values[k] = .bool(v) }
    func set(_ k: String, _ v: String) { values[k] = .string(v) }

    // Typed convenience
    var protocolValue: PuttyProtocol {
        get { PuttyProtocol(rawValue: getInt(K.protocol)) ?? .ssh }
        set { set(K.protocol, newValue.rawValue) }
    }

    // MARK: defaults  (settings.c / conf.h DEFAULT_*)
    private func loadDefaults() {
        // Session
        set(K.host, "")
        set(K.port, 22)
        set(K.protocol, PuttyProtocol.ssh.rawValue)
        set(K.closeOnExit, CloseOnExit.cleanOnly.rawValue)   // AUTO
        set(K.warnOnClose, true)
        set(K.pingInterval, 0)
        set(K.addressFamily, AddressFamily.unspec.rawValue)
        set(K.tcpNoDelay, true)
        set(K.tcpKeepalives, false)
        set(K.loghost, "")

        // Logging
        set(K.logtype, LogType.none.rawValue)
        set(K.logfilename, "putty.log")
        set(K.logxfovr, LogClash.ask.rawValue)
        set(K.logflush, true)
        set(K.logheader, true)
        set(K.logomitpass, true)
        set(K.logomitdata, false)

        // Terminal
        set(K.wrapMode, true)
        set(K.decOriginMode, false)
        set(K.lfhascr, false)
        set(K.crhaslf, false)
        set(K.bce, true)
        set(K.blinkText, false)
        set(K.answerback, "PuTTY")
        set(K.localecho, TriState.auto.rawValue)
        set(K.localedit, TriState.auto.rawValue)
        set(K.printer, "")

        // Keyboard
        set(K.bkspIsDelete, true)
        set(K.rxvtHomeEnd, false)
        set(K.funkyType, FunkyType.tilde.rawValue)
        set(K.sharrowType, ShArrowType.application.rawValue)
        set(K.appCursor, false)
        set(K.appKeypad, false)
        set(K.nethackKeypad, false)
        set(K.noApplicC, false)
        set(K.noApplicK, false)

        // Bell
        set(K.beep, BellType.def.rawValue)
        set(K.bellovl, true)
        set(K.bellovlN, 5)
        set(K.bellovlT, 2000)     // ms, PuTTY unix uses *1000 of 2*TICKSPERSEC
        set(K.bellovlS, 5000)

        // Features
        set(K.noApplicC, false); set(K.noApplicK, false)
        set(K.noMouseRep, false); set(K.noRemoteResize, false)
        set(K.noAltScreen, false); set(K.noRemoteWintitle, false)
        set(K.noRemoteClearScroll, false); set(K.noDbackspace, false)
        set(K.noRemoteCharset, false); set(K.noArabicShaping, false)
        set(K.noBidi, false); set(K.noBracketedPaste, false)
        set(K.remoteQTitleAction, 1)  // TITLE_EMPTY

        // Window
        set(K.width, 80)
        set(K.height, 24)
        set(K.savelines, 2000)
        set(K.scrollbar, true)
        set(K.scrollOnKey, false)
        set(K.scrollOnDisp, true)
        set(K.eraseToScrollback, true)

        // Appearance
        set(K.cursorType, CursorType.block.rawValue)
        set(K.blinkCur, false)
        set(K.font, "Menlo 12")
        set(K.hideMouseptr, false)
        set(K.windowBorder, 1)

        // Behaviour
        set(K.wintitle, "")
        set(K.winNameAlways, true)

        // Translation
        set(K.lineCodepage, "UTF-8")
        set(K.cjkAmbigWide, false)
        set(K.vtmode, VTMode.unicode.rawValue)
        set(K.utf8linedraw, false)
        set(K.rawcnp, false)

        // Selection
        set(K.mouseOverride, true)
        set(K.rectSelect, false)
        set(K.mouseautocopy, false)
        set(K.pasteControls, false)

        // Colours
        set(K.ansiColour, true)
        set(K.xterm256Colour, true)
        set(K.trueColour, true)
        set(K.boldStyle, BoldStyle.colour.rawValue)

        // Connection
        set(K.username, "")
        set(K.usernameFromEnv, false)
        set(K.termtype, "xterm")
        set(K.termspeed, "38400,38400")

        // SSH
        set(K.compression, false)
        set(K.sshprot, 3)
        set(K.ssh2desCBC, false)
        set(K.sshNoShell, false)
        set(K.tryagent, true)
        set(K.agentfwd, false)
        set(K.sshNoUserauth, false)
        set(K.sshShowBanner, true)
        set(K.tryKiAuth, true)
        set(K.keyfile, "")
        set(K.remoteCmd, "")
        set(K.nopty, false)
        set(K.x11Forward, false)
        set(K.x11Display, "")
        set(K.rekeyTime, 60)
        set(K.rekeyData, "1G")
        set(K.preferKnownHostKeys, true)

        // Telnet
        set(K.rfcEnviron, false)
        set(K.passiveTelnet, false)
        set(K.telnetKeyboard, false)
        set(K.telnetNewline, true)

        // Rlogin
        set(K.localusername, "")

        // Serial
        set(K.serline, "/dev/cu.usbserial")
        set(K.serspeed, 9600)
        set(K.serdatabits, 8)
        set(K.serstopbits, 2)   // halfbits
        set(K.serparity, SerParity.none.rawValue)
        set(K.serflow, SerFlow.xonxoff.rawValue)
    }
}

// MARK: - Keys (match PuTTY save keywords where applicable)
enum K {
    static let host = "HostName"
    static let port = "PortNumber"
    static let `protocol` = "Protocol"
    static let closeOnExit = "CloseOnExit"
    static let warnOnClose = "WarnOnClose"
    static let pingInterval = "PingInterval"
    static let addressFamily = "AddressFamily"
    static let tcpNoDelay = "TCPNoDelay"
    static let tcpKeepalives = "TCPKeepalives"
    static let loghost = "LogHost"

    static let logtype = "LogType"
    static let logfilename = "LogFileName"
    static let logxfovr = "LogFileClash"
    static let logflush = "LogFlush"
    static let logheader = "LogHeader"
    static let logomitpass = "SSHLogOmitPasswords"
    static let logomitdata = "SSHLogOmitData"

    static let wrapMode = "AutoWrapMode"
    static let decOriginMode = "DECOriginMode"
    static let lfhascr = "LFImpliesCR"
    static let crhaslf = "CRImpliesLF"
    static let bce = "BCE"
    static let blinkText = "BlinkText"
    static let answerback = "Answerback"
    static let localecho = "LocalEcho"
    static let localedit = "LocalEdit"
    static let printer = "Printer"

    static let bkspIsDelete = "BackspaceIsDelete"
    static let rxvtHomeEnd = "RXVTHomeEnd"
    static let funkyType = "LinuxFunctionKeys"
    static let sharrowType = "ShiftedArrowKeys"
    static let appCursor = "ApplicationCursorKeys"
    static let appKeypad = "ApplicationKeypad"
    static let nethackKeypad = "NetHackKeypad"
    static let noApplicC = "NoApplicationCursors"
    static let noApplicK = "NoApplicationKeys"
    static let noMouseRep = "NoMouseReporting"
    static let noRemoteResize = "NoRemoteResize"
    static let noAltScreen = "NoAltScreen"
    static let noRemoteWintitle = "NoRemoteWinTitle"
    static let noRemoteClearScroll = "NoRemoteClearScroll"
    static let noDbackspace = "NoDBackspace"
    static let noRemoteCharset = "NoRemoteCharset"
    static let noArabicShaping = "DisableArabicShaping"
    static let noBidi = "DisableBidi"
    static let noBracketedPaste = "DisableBracketedPaste"
    static let remoteQTitleAction = "RemoteQTitleAction"

    static let beep = "Beep"
    static let bellovl = "BellOverload"
    static let bellovlN = "BellOverloadN"
    static let bellovlT = "BellOverloadT"
    static let bellovlS = "BellOverloadS"

    static let width = "TermWidth"
    static let height = "TermHeight"
    static let savelines = "ScrollbackLines"
    static let scrollbar = "ScrollBar"
    static let scrollOnKey = "ScrollOnKey"
    static let scrollOnDisp = "ScrollOnDisp"
    static let eraseToScrollback = "EraseToScrollback"

    static let cursorType = "CurType"
    static let blinkCur = "BlinkCur"
    static let font = "Font"
    static let hideMouseptr = "HideMousePtr"
    static let windowBorder = "WindowBorder"

    static let wintitle = "WinTitle"
    static let winNameAlways = "WinNameAlways"

    static let lineCodepage = "LineCodePage"
    static let cjkAmbigWide = "CJKAmbigWide"
    static let vtmode = "FontVTMode"
    static let utf8linedraw = "UTF8linedraw"
    static let rawcnp = "RawCNP"

    static let mouseOverride = "MouseOverride"
    static let rectSelect = "RectSelect"
    static let mouseautocopy = "MouseAutocopy"
    static let pasteControls = "PasteControls"

    static let ansiColour = "ANSIColour"
    static let xterm256Colour = "Xterm256Colour"
    static let trueColour = "TrueColour"
    static let boldStyle = "BoldAsColour"

    static let username = "UserName"
    static let usernameFromEnv = "UserNameFromEnvironment"
    static let termtype = "TerminalType"
    static let termspeed = "TerminalSpeed"

    static let compression = "Compression"
    static let sshprot = "SshProt"
    static let ssh2desCBC = "SSH2DES"
    static let sshNoShell = "SshNoShell"
    static let tryagent = "TryAgent"
    static let agentfwd = "AgentFwd"
    static let sshNoUserauth = "SshNoAuth"
    static let sshShowBanner = "SshBanner"
    static let tryKiAuth = "AuthKI"
    static let keyfile = "PublicKeyFile"
    static let remoteCmd = "RemoteCommand"
    static let nopty = "NoPTY"
    static let x11Forward = "X11Forward"
    static let x11Display = "X11Display"
    static let rekeyTime = "RekeyTime"
    static let rekeyData = "RekeyBytes"
    static let preferKnownHostKeys = "PreferKnownHostKeys"

    static let rfcEnviron = "RFCEnviron"
    static let passiveTelnet = "PassiveTelnet"
    static let telnetKeyboard = "TelnetKey"
    static let telnetNewline = "TelnetRet"

    static let localusername = "LocalUserName"

    static let serline = "SerialLine"
    static let serspeed = "SerialSpeed"
    static let serdatabits = "SerialDataBits"
    static let serstopbits = "SerialStopHalfbits"
    static let serparity = "SerialParity"
    static let serflow = "SerialFlowControl"
}
