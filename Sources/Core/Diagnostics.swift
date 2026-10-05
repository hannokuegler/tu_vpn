// Fehler erkennen (aus openconnect-Ausgaben und Netzwerkfehlern) und den Tunnel-Log auswerten.
// openconnect läuft mit LC_ALL=C, seine eigenen Meldungen sind also Englisch; Texte des TU-Servers
// können Deutsch oder Englisch sein.

import Foundation

enum VpnFailure: Equatable {
    case noInternet          // offline, DNS kaputt, WLAN-Anmeldeseite
    case serverUnreachable   // vpn.tuwien.ac.at antwortet nicht
    case passwordRejected    // Login abgelehnt, bevor nach dem MFA-Code gefragt wurde
    case mfaRejected         // Login abgelehnt, nachdem der MFA-Code abgefragt wurde
    case notAuthorized       // Account ohne VPN-Berechtigung / nicht aktiviert
    case sessionLimit        // mehr als 3 gleichzeitige Sessions
    case sessionExpired      // Cookie abgelaufen oder Server-Zertifikat gewechselt → still neu einloggen
    case timeout
    case unknown
}

enum FailureClassifier {
    /// Ordnet die Ausgabe von openconnect (Anmeldung oder Tunnel) einem Fehlerbild zu.
    static func classify(_ output: String) -> VpnFailure {
        let text = output.lowercased()
        func containsAny(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }

        if containsAny(["simultaneous", "maximum number of", "max-simultaneous", "session limit",
                        "too many sessions", "sessions exceeded", "login limit"]) {
            return .sessionLimit
        }
        if containsAny(["cookie was rejected", "cookie is no longer valid", "invalid cookie",
                        "certificate didn't match", "certificate did not match"]) {
            return .sessionExpired
        }
        if containsAny(["unauthorized connection mechanism", "not authorized", "not permitted",
                        "login denied", "access denied", "no vpn access"]) {
            return .notAuthorized
        }
        if let loginFailed = firstRange(in: text, of: ["login failed", "anmeldung fehlgeschlagen",
                                                       "authentication failed"]) {
            // Der TU-Server fragt den MFA-Code erst nach einem korrekten Passwort ab.
            if let mfaPrompt = firstRange(in: text, of: ["two-factor", "zwei-faktor"]),
               mfaPrompt.lowerBound < loginFailed.lowerBound {
                return .mfaRejected
            }
            return .passwordRejected
        }
        if containsAny(["getaddrinfo failed", "nodename nor servname", "network is unreachable",
                        "network is down", "temporary failure in name resolution"]) {
            return .noInternet
        }
        if containsAny(["failed to connect to host", "failed to open https connection", "connection refused",
                        "operation timed out", "connection timed out", "no route to host",
                        "failed to reconnect", "ssl connection failure"]) {
            return .serverUnreachable
        }
        return .unknown
    }

    /// Vorabprüfung per HTTPS: welche Netzwerkfehler heißen was?
    static func classify(urlErrorCode code: URLError.Code) -> VpnFailure {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost,
             .dnsLookupFailed, .networkConnectionLost, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .appTransportSecurityRequiresSecureConnection:
            return .noInternet
        case .cannotConnectToHost, .timedOut:
            return .serverUnreachable
        default:
            return .unknown
        }
    }

    private static func firstRange(in text: String, of needles: [String]) -> Range<String.Index>? {
        needles.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }
}

/// Letzte Zeilen einer Ausgabe für Fehlerdialoge, ohne den HTML-Banner des Servers.
func lastLines(_ text: String, _ count: Int) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: true)
        .filter { !$0.contains("<BR>") }
        .suffix(count)
        .joined(separator: "\n")
}

struct TunnelLogInfo: Equatable {
    var profile: VpnProfile?
    var address: String?
    var sessionExpiry: Date?

    /// Liest PROFIL=, „Configured as …“ und „Session authentication will expire at …“ aus /var/log/tuvpn.log.
    static func parse(_ log: String, timeZone: TimeZone = .current) -> TunnelLogInfo {
        var info = TunnelLogInfo()
        for line in log.components(separatedBy: "\n") {
            if line.hasPrefix("PROFIL=") {
                info.profile = VpnProfile(rawValue: String(line.dropFirst("PROFIL=".count)))
            } else if line.hasPrefix("Configured as ") {
                info.address = line.dropFirst("Configured as ".count)
                    .split(separator: " ").first
                    .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            } else if let range = line.range(of: "Session authentication will expire at ") {
                info.sessionExpiry = parseExpiry(String(line[range.upperBound...]), timeZone: timeZone)
            }
        }
        return info
    }

    /// openconnect schreibt z. B. `Sat, 10 Oct 2026 12:39:16 CEST` in lokaler Zeit; Zonen-Kürzel
    /// wie CEST sind mehrdeutig und werden ignoriert.
    static func parseExpiry(_ raw: String, timeZone: TimeZone) -> Date? {
        var words = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        if let last = words.last, last.allSatisfy({ $0.isLetter }) { words.removeLast() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss"
        return formatter.date(from: words.joined(separator: " "))
    }
}
