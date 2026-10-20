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
        let values = Self.authenticateValues(authenticateOutput)
        guard let cookie = values["COOKIE"], let connectUrl = values["CONNECT_URL"],
              let fingerprint = values["FINGERPRINT"] else { return nil }
        self.init(cookie: cookie, connectUrl: connectUrl, serverFingerprint: fingerprint)
    }

    /// Warum `init?(authenticateOutput:)` scheitert — für Fehlermeldung und Anmelde-Log.
    /// Nennt nie den Inhalt des Cookies; URL und Pin sind nicht geheim.
    static func rejectionReason(authenticateOutput: String) -> String? {
        let values = authenticateValues(authenticateOutput)
        guard let cookie = values["COOKIE"] else { return "COOKIE fehlt" }
        guard isValidCookie(cookie) else {
            return "COOKIE ungültig (\(cookie.utf8.count) Zeichen" + forbiddenCharacterNames(cookie) + ")"
        }
        guard let connectUrl = values["CONNECT_URL"] else { return "CONNECT_URL fehlt" }
        guard isValidConnectUrl(connectUrl) else { return "CONNECT_URL ungültig: \(connectUrl.prefix(200))" }
        guard let fingerprint = values["FINGERPRINT"] else { return "FINGERPRINT fehlt" }
        guard isValidFingerprint(fingerprint) else { return "FINGERPRINT ungültig: \(fingerprint.prefix(100))" }
        return nil
    }

    /// Benennt nur die verbotenen Zeichen (je einmal), nie den Rest des Cookies.
    private static func forbiddenCharacterNames(_ cookie: String) -> String {
        var names: [String] = []
        for scalar in cookie.unicodeScalars {
            let name: String
            switch scalar.value {
            case 0x20...0x7E: continue
            case 0..<0x20, 0x7F: name = "Steuerzeichen"
            default: name = "Nicht-ASCII"
            }
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "" : ", verboten: " + names.joined(separator: " ")
    }

    private static func authenticateValues(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<separator])
            var value = String(line[line.index(after: separator)...])
            if value.count >= 2 && value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            values[name] = value
        }
        return values
    }

    // MARK: Prüfregeln

    /// Druckbares ASCII inkl. Leerzeichen, ohne Steuerzeichen und Zeilenumbruch. Das Cookie steht nie in
    /// einem Shell-Befehl — es geht nur über eine 0600-Datei bzw. stdin an `--cookie-on-stdin`, deshalb
    /// sind Quotes und Leerzeichen harmlos (der TU-Server liefert seit Okt 2026 solche Cookies).
    static func isValidCookie(_ cookie: String) -> Bool {
        guard (1...8192).contains(cookie.utf8.count) else { return false }
        return cookie.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
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
