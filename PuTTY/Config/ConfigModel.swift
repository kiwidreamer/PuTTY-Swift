import Foundation

// A small declarative description of a configuration panel, mirroring the
// controls PuTTY builds in config.c (ctrl_checkbox / ctrl_editbox / …).  The
// window renders these generically and binds them to a Conf instance.

enum EditKind { case string, int }

indirect enum Control {
    case group(String?, [Control])                       // a titled box of controls
    case checkbox(String, String)                        // label, conf key
    case checkboxInverted(String, String)                // stored meaning inverted
    case editbox(String, String, EditKind)               // label, key, kind
    case radio(String?, String, Int, [(String, Int)])    // label, key, columns, options
    case radioBool(String?, String, [(String, Bool)])    // label, key(bool), options
    case droplist(String, String, [(String, Int)])       // label, key, options
    case text(String)                                    // static help text
    case font(String, String)                            // label, key
    case fileField(String, String)                       // label, key (text + Browse)
    case colours                                         // the Colours editor
    case custom(String)                                  // identifier handled by the controller
}

struct Panel {
    let path: String            // "Connection/SSH/Auth"
    let title: String           // the heading shown at the top of the panel
    let controls: [Control]
}

/// Builds the full set of panels for a given configuration, in the order and
/// with the categories PuTTY shows.  Panels depend on the selected protocol
/// just as config.c does.
enum ConfigPanels {
    static func build(conf: Conf, midSession: Bool) -> [Panel] {
        let proto = conf.protocolValue
        var panels: [Panel] = []

        // Session
        panels.append(Panel(path: "Session", title: "Basic options for your PuTTY session",
                            controls: sessionControls(midSession: midSession)))
        panels.append(Panel(path: "Session/Logging", title: "Options controlling session logging",
                            controls: loggingControls()))

        // Terminal
        panels.append(Panel(path: "Terminal", title: "Options controlling the terminal emulation",
                            controls: terminalControls()))
        panels.append(Panel(path: "Terminal/Keyboard", title: "Options controlling the effects of keys",
                            controls: keyboardControls()))
        panels.append(Panel(path: "Terminal/Bell", title: "Options controlling the terminal bell",
                            controls: bellControls()))
        panels.append(Panel(path: "Terminal/Features", title: "Enabling and disabling advanced terminal features",
                            controls: featuresControls()))

        // Window
        panels.append(Panel(path: "Window", title: "Options controlling PuTTY's window",
                            controls: windowControls()))
        panels.append(Panel(path: "Window/Appearance", title: "Configure the appearance of PuTTY's window",
                            controls: appearanceControls()))
        panels.append(Panel(path: "Window/Behaviour", title: "Configure the behaviour of PuTTY's window",
                            controls: behaviourControls()))
        panels.append(Panel(path: "Window/Translation", title: "Options controlling character set translation",
                            controls: translationControls()))
        panels.append(Panel(path: "Window/Selection", title: "Options controlling copy and paste",
                            controls: selectionControls()))
        panels.append(Panel(path: "Window/Colours", title: "Options controlling use of colours",
                            controls: coloursControls()))

        // Connection (network protocols only)
        if proto.isNetwork {
            panels.append(Panel(path: "Connection", title: "Options controlling the connection",
                                controls: connectionControls(midSession: midSession)))
            if !midSession {
                panels.append(Panel(path: "Connection/Data", title: "Data to send to the server",
                                    controls: dataControls()))
            }
        }

        switch proto {
        case .ssh:
            panels.append(Panel(path: "Connection/SSH", title: "Options controlling SSH connections",
                                controls: sshControls(midSession: midSession)))
            panels.append(Panel(path: "Connection/SSH/Auth", title: "Options controlling SSH authentication",
                                controls: sshAuthControls()))
            panels.append(Panel(path: "Connection/SSH/Auth/Credentials", title: "Credentials to authenticate with",
                                controls: sshCredControls()))
            panels.append(Panel(path: "Connection/SSH/TTY", title: "Remote terminal settings",
                                controls: sshTTYControls()))
            panels.append(Panel(path: "Connection/SSH/X11", title: "Options controlling SSH X11 forwarding",
                                controls: sshX11Controls()))
        case .serial:
            panels.append(Panel(path: "Connection/Serial", title: "Options controlling local serial lines",
                                controls: serialControls(midSession: midSession)))
        case .telnet:
            panels.append(Panel(path: "Connection/Telnet", title: "Options controlling Telnet connections",
                                controls: telnetControls(midSession: midSession)))
        case .rlogin:
            panels.append(Panel(path: "Connection/Rlogin", title: "Options controlling Rlogin connections",
                                controls: rloginControls()))
        default: break
        }

        return panels
    }

    // MARK: Session
    private static func sessionControls(midSession: Bool) -> [Control] {
        var c: [Control] = []
        if !midSession {
            c.append(.group("Specify the destination you want to connect to", [
                .custom("hostport"),
                .custom("protocol")
            ]))
        }
        c.append(.group("Load, save or delete a stored session", [
            .custom("sessions")
        ]))
        c.append(.radio("Close window on exit:", K.closeOnExit, 3, [
            ("Always", CloseOnExit.always.rawValue),
            ("Never", CloseOnExit.never.rawValue),
            ("Only on clean exit", CloseOnExit.cleanOnly.rawValue)
        ]))
        return c
    }

    private static func loggingControls() -> [Control] {
        [
            .radio("Session logging:", K.logtype, 2, [
                ("None", LogType.none.rawValue),
                ("Printable output", LogType.ascii.rawValue),
                ("All session output", LogType.debug.rawValue),
                ("SSH packets", LogType.packets.rawValue),
                ("SSH packets and raw data", LogType.sshraw.rawValue)
            ]),
            .fileField("Log file name:", K.logfilename),
            .text("(Log file name can contain &Y, &M, &D for date, &T for time, &H for host name, and &P for port number)"),
            .radio("What to do if the log file already exists:", K.logxfovr, 1, [
                ("Always overwrite it", LogClash.overwrite.rawValue),
                ("Always append to the end of it", LogClash.append.rawValue),
                ("Ask the user every time", LogClash.ask.rawValue)
            ]),
            .checkbox("Flush log file frequently", K.logflush),
            .checkbox("Include header", K.logheader)
        ]
    }

    // MARK: Terminal
    private static func terminalControls() -> [Control] {
        [
            .group("Set various terminal options", [
                .checkbox("Auto wrap mode initially on", K.wrapMode),
                .checkbox("DEC Origin Mode initially on", K.decOriginMode),
                .checkbox("Implicit CR in every LF", K.lfhascr),
                .checkbox("Implicit LF in every CR", K.crhaslf),
                .checkbox("Use background colour to erase screen", K.bce),
                .checkbox("Enable blinking text", K.blinkText),
                .editbox("Answerback to ^E:", K.answerback, .string)
            ]),
            .group("Line discipline options", [
                .radio("Local echo:", K.localecho, 3, triStateOptions()),
                .radio("Local line editing:", K.localedit, 3, triStateOptions())
            ])
        ]
    }

    private static func triStateOptions() -> [(String, Int)] {
        [("Auto", TriState.auto.rawValue),
         ("Force on", TriState.forceOn.rawValue),
         ("Force off", TriState.forceOff.rawValue)]
    }

    private static func keyboardControls() -> [Control] {
        [
            .group("Change the sequences sent by:", [
                .radioBool("The Backspace key", K.bkspIsDelete, [("Control-H", false), ("Control-? (127)", true)]),
                .radioBool("The Home and End keys", K.rxvtHomeEnd, [("Standard", false), ("rxvt", true)]),
                .radio("The Function keys and keypad", K.funkyType, 3, [
                    ("ESC[n~", FunkyType.tilde.rawValue),
                    ("Linux", FunkyType.linux.rawValue),
                    ("Xterm R6", FunkyType.xterm.rawValue),
                    ("VT400", FunkyType.vt400.rawValue),
                    ("VT100+", FunkyType.vt100p.rawValue),
                    ("SCO", FunkyType.sco.rawValue),
                    ("Xterm 216+", FunkyType.xterm216.rawValue)
                ]),
                .radio("Shift/Ctrl/Alt with the arrow keys", K.sharrowType, 2, [
                    ("Ctrl toggles app mode", ShArrowType.application.rawValue),
                    ("xterm-style bitmap", ShArrowType.bitmap.rawValue)
                ])
            ]),
            .group("Application keypad settings:", [
                .radioBool("Initial state of cursor keys:", K.appCursor, [("Normal", false), ("Application", true)]),
                .radioBool("Initial state of numeric keypad:", K.appKeypad, [("Normal", false), ("Application", true)])
            ])
        ]
    }

    private static func bellControls() -> [Control] {
        [
            .radio("Action to happen when a bell occurs:", K.beep, 1, [
                ("None (bell disabled)", BellType.disabled.rawValue),
                ("Make default system alert sound", BellType.def.rawValue),
                ("Visual bell (flash window)", BellType.visual.rawValue)
            ]),
            .group("Control the bell overload behaviour", [
                .checkbox("Bell is temporarily disabled when over-used", K.bellovl),
                .editbox("Over-use means this many bells...", K.bellovlN, .int)
            ])
        ]
    }

    private static func featuresControls() -> [Control] {
        [
            .checkbox("Disable application cursor keys mode", K.noApplicC),
            .checkbox("Disable application keypad mode", K.noApplicK),
            .checkbox("Disable xterm-style mouse reporting", K.noMouseRep),
            .checkbox("Disable remote-controlled terminal resizing", K.noRemoteResize),
            .checkbox("Disable switching to alternate terminal screen", K.noAltScreen),
            .checkbox("Disable remote-controlled window title changing", K.noRemoteWintitle),
            .checkbox("Disable remote-controlled clearing of scrollback", K.noRemoteClearScroll),
            .checkbox("Disable destructive backspace on server sending ^?", K.noDbackspace),
            .checkbox("Disable bidirectional text display", K.noBidi),
            .checkbox("Disable bracketed paste mode", K.noBracketedPaste)
        ]
    }

    // MARK: Window
    private static func windowControls() -> [Control] {
        [
            .group("Set the size of the window", [
                .editbox("Columns", K.width, .int),
                .editbox("Rows", K.height, .int)
            ]),
            .group("Control the scrollback in the window", [
                .editbox("Lines of scrollback", K.savelines, .int),
                .checkbox("Display scrollbar", K.scrollbar),
                .checkbox("Reset scrollback on keypress", K.scrollOnKey),
                .checkbox("Reset scrollback on display activity", K.scrollOnDisp),
                .checkbox("Push erased text into scrollback", K.eraseToScrollback)
            ])
        ]
    }

    private static func appearanceControls() -> [Control] {
        [
            .group("Adjust the use of the cursor", [
                .radio("Cursor appearance:", K.cursorType, 3, [
                    ("Block", CursorType.block.rawValue),
                    ("Underline", CursorType.underline.rawValue),
                    ("Vertical line", CursorType.verticalLine.rawValue)
                ]),
                .checkbox("Cursor blinks", K.blinkCur)
            ]),
            .group("Font settings", [
                .font("Font used in the terminal window", K.font)
            ]),
            .group("Adjust the use of the mouse pointer", [
                .checkbox("Hide mouse pointer when typing in window", K.hideMouseptr)
            ]),
            .group("Adjust the window border", [
                .editbox("Gap between text and window edge:", K.windowBorder, .int)
            ])
        ]
    }

    private static func behaviourControls() -> [Control] {
        [
            .group("Adjust the behaviour of the window title", [
                .editbox("Window title:", K.wintitle, .string),
                .checkboxInverted("Separate window and icon titles", K.winNameAlways)
            ]),
            .group(nil, [
                .checkbox("Warn before closing window", K.warnOnClose)
            ])
        ]
    }

    private static func translationControls() -> [Control] {
        [
            .group("Character set translation", [
                .droplist("Remote character set:", K.lineCodepage, [
                    ("UTF-8", 0), ("ISO-8859-1", 1), ("ISO-8859-15", 2)
                ])
            ]),
            .group(nil, [
                .checkbox("Treat CJK ambiguous characters as wide", K.cjkAmbigWide)
            ]),
            .group("Adjust how PuTTY handles line drawing characters", [
                .radio("Handling of line drawing characters:", K.vtmode, 1, [
                    ("Use Unicode line drawing code points", VTMode.unicode.rawValue),
                    ("Poor man's line drawing (+, - and |)", VTMode.poorman.rawValue)
                ]),
                .checkbox("Copy and paste line drawing characters as lqqqk", K.rawcnp),
                .checkbox("Enable VT100 line drawing even in UTF-8 mode", K.utf8linedraw)
            ])
        ]
    }

    private static func selectionControls() -> [Control] {
        [
            .group("Control use of mouse", [
                .checkbox("Shift overrides application's use of mouse", K.mouseOverride),
                .radioBool("Default selection mode (Alt+drag does the other one):", K.rectSelect,
                           [("Normal", false), ("Rectangular block", true)])
            ]),
            .group("Assign copy/paste actions to clipboards", [
                .checkbox("Auto-copy selected text to system clipboard", K.mouseautocopy)
            ]),
            .group("Control pasting of text from clipboard to terminal", [
                .checkbox("Permit control characters in pasted text", K.pasteControls)
            ])
        ]
    }

    private static func coloursControls() -> [Control] {
        [
            .group("General options for colour usage", [
                .checkbox("Allow terminal to specify ANSI colours", K.ansiColour),
                .checkbox("Allow terminal to use xterm 256-colour mode", K.xterm256Colour),
                .checkbox("Allow terminal to use 24-bit colours", K.trueColour),
                .radio("Indicate bolded text by changing:", K.boldStyle, 3, [
                    ("The font", BoldStyle.font.rawValue),
                    ("The colour", BoldStyle.colour.rawValue),
                    ("Both", BoldStyle.both.rawValue)
                ])
            ]),
            .group("Adjust the precise colours PuTTY displays", [ .colours ])
        ]
    }

    // MARK: Connection
    private static func connectionControls(midSession: Bool) -> [Control] {
        var c: [Control] = [
            .group("Sending of null packets to keep session active", [
                .editbox("Seconds between keepalives (0 to turn off)", K.pingInterval, .int)
            ])
        ]
        if !midSession {
            c.append(.group("Low-level TCP connection options", [
                .checkbox("Disable Nagle's algorithm (TCP_NODELAY option)", K.tcpNoDelay),
                .checkbox("Enable TCP keepalives (SO_KEEPALIVE option)", K.tcpKeepalives)
            ]))
            c.append(.group("Internet protocol version", [
                .radio(nil, K.addressFamily, 3, [
                    ("Auto", AddressFamily.unspec.rawValue),
                    ("IPv4", AddressFamily.ipv4.rawValue),
                    ("IPv6", AddressFamily.ipv6.rawValue)
                ])
            ]))
            c.append(.group("Logical name of remote host", [
                .editbox("Logical name of remote host (e.g. for SSH key lookup):", K.loghost, .string)
            ]))
        }
        return c
    }

    private static func dataControls() -> [Control] {
        [
            .group("Login details", [
                .editbox("Auto-login username", K.username, .string),
                .radioBool("When username is not specified:", K.usernameFromEnv,
                           [("Prompt", false), ("Use system username", true)])
            ]),
            .group("Terminal details", [
                .editbox("Terminal-type string", K.termtype, .string),
                .editbox("Terminal speeds", K.termspeed, .string)
            ])
        ]
    }

    // MARK: SSH
    private static func sshControls(midSession: Bool) -> [Control] {
        var c: [Control] = []
        if !midSession {
            c.append(.group("Data to send to the server", [
                .editbox("Remote command:", K.remoteCmd, .string),
                .checkbox("Don't start a shell or command at all", K.sshNoShell)
            ]))
        }
        c.append(.group("Protocol options", [
            .checkbox("Enable compression", K.compression),
            .radio("SSH protocol version:", K.sshprot, 2, [("2", 3), ("1 (INSECURE)", 0)])
        ]))
        c.append(.group("Encryption options", [
            .checkbox("Enable legacy use of single-DES in SSH-2", K.ssh2desCBC)
        ]))
        return c
    }

    private static func sshAuthControls() -> [Control] {
        [
            .group(nil, [
                .checkbox("Display pre-authentication banner (SSH-2 only)", K.sshShowBanner),
                .checkbox("Bypass authentication entirely (SSH-2 only)", K.sshNoUserauth)
            ]),
            .group("Authentication methods", [
                .checkbox("Attempt authentication using the SSH agent", K.tryagent),
                .checkbox("Attempt \"keyboard-interactive\" auth (SSH-2)", K.tryKiAuth)
            ]),
            .group("Other authentication-related options", [
                .checkbox("Allow agent forwarding", K.agentfwd)
            ])
        ]
    }

    private static func sshCredControls() -> [Control] {
        [
            .group("Public-key authentication", [
                .fileField("Private key file for authentication:", K.keyfile)
            ])
        ]
    }

    private static func sshTTYControls() -> [Control] {
        [
            .group(nil, [
                .checkbox("Don't allocate a pseudo-terminal", K.nopty)
            ])
        ]
    }

    private static func sshX11Controls() -> [Control] {
        [
            .group("X11 forwarding", [
                .checkbox("Enable X11 forwarding", K.x11Forward),
                .editbox("X display location", K.x11Display, .string)
            ])
        ]
    }

    // MARK: Serial
    private static func serialControls(midSession: Bool) -> [Control] {
        var c: [Control] = []
        if !midSession {
            c.append(.group("Select a serial line", [
                .editbox("Serial line to connect to", K.serline, .string)
            ]))
        }
        c.append(.group("Configure the serial line", [
            .editbox("Speed (baud)", K.serspeed, .int),
            .editbox("Data bits", K.serdatabits, .int),
            .editbox("Stop bits (half-bits: 2 = 1 bit)", K.serstopbits, .int),
            .droplist("Parity", K.serparity, [
                ("None", SerParity.none.rawValue), ("Odd", SerParity.odd.rawValue),
                ("Even", SerParity.even.rawValue), ("Mark", SerParity.mark.rawValue),
                ("Space", SerParity.space.rawValue)
            ]),
            .droplist("Flow control", K.serflow, [
                ("None", SerFlow.none.rawValue), ("XON/XOFF", SerFlow.xonxoff.rawValue),
                ("RTS/CTS", SerFlow.rtscts.rawValue), ("DSR/DTR", SerFlow.dsrdtr.rawValue)
            ])
        ]))
        return c
    }

    private static func telnetControls(midSession: Bool) -> [Control] {
        var c: [Control] = []
        if !midSession {
            c.append(.group("Telnet protocol adjustments", [
                .radioBool("Handling of OLD_ENVIRON ambiguity:", K.rfcEnviron,
                           [("BSD (commonplace)", false), ("RFC 1408 (unusual)", true)]),
                .radioBool("Telnet negotiation mode:", K.passiveTelnet,
                           [("Passive", true), ("Active", false)])
            ]))
        }
        c.append(.group(nil, [
            .checkbox("Keyboard sends Telnet special commands", K.telnetKeyboard),
            .checkbox("Return key sends Telnet New Line instead of ^M", K.telnetNewline)
        ]))
        return c
    }

    private static func rloginControls() -> [Control] {
        [
            .group("Data to send to the server", [
                .editbox("Local username:", K.localusername, .string)
            ])
        ]
    }
}
