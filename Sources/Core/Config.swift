// Feste Werte, VPN-Profile und die Normalisierung des TU-Logins.

import Foundation

enum Config {
    static let vpnServer = "vpn.tuwien.ac.at"
    static let studentDomain = "student.tuwien.ac.at"
    /// Laut Login-Banner des TU-Servers berechtigte Domains.
    static let allowedLoginDomains = ["student.tuwien.ac.at", "tuwien.ac.at", "extern.tuwien.ac.at"]

    static let passwordKeychainService = "TUvpn"
    static let sessionKeychainService = "TUvpn-session"
    static let userDefaultsKey = "vpnUser"
    static let onboardingDoneKey = "onboardingDone"
    /// Bundle-ID der allerersten Version — von dort wird der gespeicherte Login einmalig übernommen.
    static let legacyDefaultsDomain = "io.github.tuvpn-mac"

    // Root-eigene Orte: nur root darf in /var/log und /var/run anlegen → kein Symlink-Angriff möglich.
    static let tunnelLogPath = "/var/log/tuvpn.log"
    static let pidFilePath = "/var/run/tuvpn.pid"
    static var authLogPath: String { NSHomeDirectory() + "/Library/Logs/TUvpn-auth.log" }

    /// Nach Sleep/Wake oder WLAN-Wechsel baut openconnect den Tunnel bis zu 24 h lang selbst wieder auf
    /// (mit dem Session-Cookie, ohne Admin-Dialog). Standard von openconnect wären 300 s.
    static let reconnectTimeoutSeconds = 86_400

    static let sessionsPortalUrl = URL(string: "https://nix.kom.tuwien.ac.at/vpn-sessions")!
    static let accountHelpUrl = URL(string: "https://colab.tuwien.ac.at/x/OITjBw")!
    static let vpnHelpUrl = URL(string: "https://colab.tuwien.ac.at/spaces/SVCSP/pages/141888133/Anleitungen+TUvpn")!
    static let homebrewUrl = URL(string: "https://brew.sh")!
    static let projectUrl = URL(string: "https://github.com/hannokuegler/tu_vpn")!

    /// Nur diese Pfade werden je als root gestartet.
    static let openconnectCandidates = [
        "/opt/homebrew/bin/openconnect", // Homebrew, Apple Silicon
        "/usr/local/bin/openconnect",    // Homebrew, Intel
        "/opt/local/sbin/openconnect",   // MacPorts
    ]
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let installOpenconnectCommand = "brew install openconnect"

    static let statusRefreshSeconds: TimeInterval = 5
    static let authTimeoutSeconds: TimeInterval = 90
    static let reachabilityTimeoutSeconds: TimeInterval = 8
}

enum VpnProfile: String, CaseIterable {
    case tuOnly = "1_TU_getunnelt"
    case everything = "2_Alles_getunnelt"

    var menuTitle: String {
        switch self {
        case .tuOnly: return L("Nur TU", "TU only")
        case .everything: return L("Alles getunnelt", "All traffic")
        }
    }

    var statusBarTitle: String {
        switch self {
        case .tuOnly: return "TU"
        case .everything: return "TU+"
        }
    }

    var explanation: String {
        switch self {
        case .tuOnly:
            return L("Nur der TU-Verkehr läuft durch den Tunnel (Standard). Kann ruhig den ganzen Tag an bleiben.",
                     "Only TU traffic goes through the tunnel (default). Fine to leave on all day.")
        case .everything:
            return L("Gesamter Verkehr über die TU – für Bibliotheks-Paper & E-Journals. Danach wieder auf „Nur TU“ wechseln.",
                     "All traffic via TU – for library papers & e-journals. Switch back to “TU only” afterwards.")
        }
    }
}

enum LoginNormalizer {
    /// Macht aus der Eingabe den VPN-Benutzernamen, z. B. `E 1234 5678` → `e12345678@student.tuwien.ac.at`.
    /// `nil` heißt: kein gültiger TU-Login (Tippfehler in Domain, Sonderzeichen …).
    static func normalize(_ input: String) -> String? {
        let compact = input.lowercased().filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }

        let parts = compact.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            guard let studentId = studentLogin(parts[0]) else { return nil }
            return studentId + "@" + Config.studentDomain
        case 2:
            var (localPart, domain) = (parts[0], parts[1])
            guard Config.allowedLoginDomains.contains(domain), isValidLocalPart(localPart) else { return nil }
            if domain == Config.studentDomain, let studentId = studentLogin(localPart) { localPart = studentId }
            return localPart + "@" + domain
        default:
            return nil
        }
    }

    /// `e12345678` oder nur die Matrikelnummer (7 oder 8 Ziffern) → `e12345678`.
    private static func studentLogin(_ text: String) -> String? {
        let digits = text.hasPrefix("e") ? String(text.dropFirst()) : text
        guard (7...8).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "e" + digits
    }

    private static func isValidLocalPart(_ text: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        return !text.isEmpty && text.count <= 64 && text.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - Modus "Ohne Mac-Passwort"

enum PasswordlessState: Equatable {
    case off         // nicht eingerichtet → Admin-Dialog bei jedem Verbinden/Trennen
    case ready       // eingerichtet und aktuell
    case outdated    // läuft, aber openconnect wurde aktualisiert oder der Helper ist alt → neu einrichten
    case incomplete  // nur halb vorhanden (z. B. sudoers-Regel fehlt) → neu einrichten oder entfernen
}

enum Passwordless {
    static let installDir = "/Library/TUvpn"
    static let helperPath = "/Library/TUvpn/tuvpn-helper"
    static let versionFilePath = "/Library/TUvpn/VERSION"
    static let sudoersPath = "/etc/sudoers.d/tuvpn"
    /// Muss zu HELPER_VERSION in Helper/tuvpn-helper passen.
    static let expectedHelperVersion = 1

    /// Bewertet, was auf der Platte liegt. `currentOpenconnectSource` = aufgelöster Pfad des
    /// Homebrew-openconnect (nil, wenn Homebrew-openconnect fehlt — die Kopie läuft trotzdem).
    static func evaluate(helperInstalled: Bool, sudoersInstalled: Bool, versionFile: String?,
                         currentOpenconnectSource: String?) -> PasswordlessState {
        switch (helperInstalled, sudoersInstalled) {
        case (false, false): return .off
        case (true, true): break
        default: return .incomplete
        }
        var values: [String: String] = [:]
        for line in (versionFile ?? "").components(separatedBy: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard values["helper"] == String(expectedHelperVersion) else { return .outdated }
        if let currentOpenconnectSource, values["source"] != currentOpenconnectSource { return .outdated }
        return .ready
    }
}
