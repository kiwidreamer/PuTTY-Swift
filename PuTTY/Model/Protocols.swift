import Foundation

// PuTTY's protocol identifiers (putty.h PROT_*).
enum PuttyProtocol: Int, CaseIterable {
    case raw = 0        // PROT_RAW
    case telnet         // PROT_TELNET
    case rlogin         // PROT_RLOGIN
    case ssh            // PROT_SSH
    case serial         // PROT_SERIAL (position for UI only)
    case supdup

    /// Display name shown on the Session radio buttons.
    var displayName: String {
        switch self {
        case .raw: return "Raw"
        case .telnet: return "Telnet"
        case .rlogin: return "Rlogin"
        case .ssh: return "SSH"
        case .serial: return "Serial"
        case .supdup: return "SUPDUP"
        }
    }

    /// Default port used when the user switches protocol with the UI,
    /// mirroring config_protocols_handler in config.c.
    var defaultPort: Int {
        switch self {
        case .raw: return 0
        case .telnet: return 23
        case .rlogin: return 513
        case .ssh: return 22
        case .serial: return 0
        case .supdup: return 95
        }
    }

    var isNetwork: Bool { self != .serial }

    /// The protocol names used by PuTTY's saved-session storage.
    var storageName: String {
        switch self {
        case .raw: return "raw"
        case .telnet: return "telnet"
        case .rlogin: return "rlogin"
        case .ssh: return "ssh"
        case .serial: return "serial"
        case .supdup: return "supdup"
        }
    }

    static func fromStorage(_ s: String) -> PuttyProtocol? {
        allCases.first { $0.storageName == s }
    }

    /// Protocols that get a top-level radio button on the Session panel
    /// (as in PuTTY: SSH and Serial), with the rest in an "Other" droplist.
    static let radioProtocols: [PuttyProtocol] = [.ssh, .serial]
    static let otherProtocols: [PuttyProtocol] = [.raw, .telnet, .rlogin, .supdup]
}
