import Foundation

/// Persists saved sessions.  PuTTY on Unix keeps one file per session under
/// ~/.putty/sessions; here we keep the same spirit using one plist file per
/// session under ~/Library/Application Support/PuTTY/sessions, with the same
/// PuTTY key names inside so the data is recognisable.
final class SettingsStore {
    static let shared = SettingsStore()

    private let fm = FileManager.default
    private let sessionsDir: URL

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PuTTY", isDirectory: true)
        sessionsDir = base.appendingPathComponent("sessions", isDirectory: true)
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    /// Session names, "Default Settings" first (as PuTTY shows it).
    func sessionList() -> [String] {
        let names = (try? fm.contentsOfDirectory(at: sessionsDir,
                                                 includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "plist" }
            .map { decodeName($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? []
        return names
    }

    private func url(for name: String) -> URL {
        sessionsDir.appendingPathComponent(encodeName(name)).appendingPathExtension("plist")
    }

    func save(_ conf: Conf, as name: String) {
        var dict: [String: Any] = [:]
        for (k, v) in conf.values {
            switch v {
            case .int(let i): dict[k] = i
            case .bool(let b): dict[k] = b
            case .string(let s): dict[k] = s
            }
        }
        // Store protocol by its storage name, as PuTTY does.
        dict[K.protocol] = conf.protocolValue.storageName
        let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try? data?.write(to: url(for: name))
    }

    func load(_ name: String) -> Conf? {
        guard let data = try? Data(contentsOf: url(for: name)),
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        let conf = Conf()   // starts from defaults, giving us each key's type
        for (k, v) in dict {
            if k == K.protocol {
                if let s = v as? String, let p = PuttyProtocol.fromStorage(s) {
                    conf.protocolValue = p
                } else if let i = v as? Int {
                    conf.set(K.protocol, i)
                }
                continue
            }
            // Coerce the stored value to the type the default declares.
            switch conf.values[k] {
            case .bool:
                if let b = v as? Bool { conf.set(k, b) }
                else if let i = v as? Int { conf.set(k, i != 0) }
            case .int:
                if let i = v as? Int { conf.set(k, i) }
                else if let b = v as? Bool { conf.set(k, b ? 1 : 0) }
            case .string:
                if let s = v as? String { conf.set(k, s) }
            case nil:
                if let b = v as? Bool { conf.set(k, b) }
                else if let i = v as? Int { conf.set(k, i) }
                else if let s = v as? String { conf.set(k, s) }
            }
        }
        return conf
    }

    func delete(_ name: String) {
        try? fm.removeItem(at: url(for: name))
    }

    // Session names may contain characters awkward in a filename; encode them.
    private func encodeName(_ s: String) -> String {
        var out = ""
        for b in Array(s.utf8) {
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) ||
               (b >= 0x61 && b <= 0x7a) || b == 0x2d || b == 0x2e {
                out.append(Character(UnicodeScalar(b)))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }
    private func decodeName(_ s: String) -> String {
        var bytes = [UInt8]()
        let chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == 0x25, i + 2 < chars.count,
               let hi = hex(chars[i+1]), let lo = hex(chars[i+2]) {
                bytes.append(UInt8(hi * 16 + lo)); i += 3
            } else { bytes.append(chars[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    private func hex(_ c: UInt8) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c - 0x30)
        case 0x41...0x46: return Int(c - 0x41 + 10)
        case 0x61...0x66: return Int(c - 0x61 + 10)
        default: return nil
        }
    }
}
