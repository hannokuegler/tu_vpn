// Die TU-Session (Cookie + Server-Adresse + Zertifikats-Pin) und ihre strenge Prüfung.
// Alles, was später in den root-Befehl wandert, muss hier durch — auch Daten aus dem Schlüsselbund,
// denn den könnte ein anderes Programm des Users mit präparierten Werten beschreiben.

import Foundation

struct VpnSession: Equatable {
    let cookie: String
    let connectUrl: String
    let serverFingerprint: String

    init?(cookie: String, connectUrl: String, serverFingerprint: String) {
        guard Self.isValidCookie(cookie), Self.isValidConnectUrl(connectUrl),
              Self.isValidFingerprint(serverFingerprint) else { return nil }
        self.cookie = cookie
        self.connectUrl = connectUrl
        self.serverFingerprint = serverFingerprint
    }

    // MARK: Schlüsselbund-Format: drei Zeilen

    var serialized: String { [cookie, connectUrl, serverFingerprint].joined(separator: "\n") }

    init?(serialized: String) {
        let parts = serialized.components(separatedBy: "\n")
        guard parts.count == 3 else { return nil }
        self.init(cookie: parts[0], connectUrl: parts[1], serverFingerprint: parts[2])
    }

    /// Liest COOKIE='…', CONNECT_URL='…', FINGERPRINT='…' aus der Standardausgabe von `openconnect --authenticate`.
    init?(authenticateOutput: String) {
        var values: [String: String] = [:]
        for line in authenticateOutput.components(separatedBy: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<separator])
            var value = String(line[line.index(after: separator)...])
            if value.count >= 2 && value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            values[name] = value
        }
        guard let cookie = values["COOKIE"], let connectUrl = values["CONNECT_URL"],
              let fingerprint = values["FINGERPRINT"] else { return nil }
        self.init(cookie: cookie, connectUrl: connectUrl, serverFingerprint: fingerprint)
    }

    // MARK: Prüfregeln

    /// Druckbares ASCII ohne Leerzeichen, Quotes und Backslash; das Cookie geht nur über eine Datei an root.
    static func isValidCookie(_ cookie: String) -> Bool {
        guard (1...8192).contains(cookie.utf8.count) else { return false }
        return cookie.unicodeScalars.allSatisfy { scalar in
            (0x21...0x7E).contains(scalar.value) && !"'\"\\`".unicodeScalars.contains(scalar)
        }
    }

    /// Nur `https://vpn.tuwien.ac.at[:443]/…` mit harmlosen Zeichen.
    static func isValidConnectUrl(_ url: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/:?=&%+")
        guard url.count <= 512, url.allSatisfy({ allowed.contains($0) }),
              let components = URLComponents(string: url) else { return false }
        return components.scheme == "https"
            && components.host?.lowercased() == Config.vpnServer
            && components.user == nil && components.password == nil
            && (components.port == nil || components.port == 443)
            && url.lowercased().hasPrefix("https://" + Config.vpnServer)
    }

    /// `pin-sha256:` + Base64 eines SHA-256 (32 Byte → 44 Zeichen).
    static func isValidFingerprint(_ fingerprint: String) -> Bool {
        let prefix = "pin-sha256:"
        guard fingerprint.hasPrefix(prefix) else { return false }
        let encoded = String(fingerprint.dropFirst(prefix.count))
        let base64Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard encoded.count == 44, encoded.allSatisfy({ base64Alphabet.contains($0) }),
              let digest = Data(base64Encoded: encoded) else { return false }
        return digest.count == 32
    }
}
