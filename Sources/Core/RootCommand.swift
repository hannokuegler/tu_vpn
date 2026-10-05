// Baut die Shell-Befehle, die über den macOS-Admin-Dialog als root laufen.
// Regeln: jede Eingabe wird geprüft (sonst kein Befehl), alles Variable steht in einfachen Quotes,
// Geheimnisse stehen nie im Befehl (das Cookie kommt aus einer 0600-Datei über stdin).

import Foundation

enum TunnelSignal: String {
    case disconnectKeepingSession = "HUP" // Tunnel zu, Session bleibt beim Server offen
    case logout = "INT"                   // Session beim Server abmelden
}

enum RootCommand {
    /// Startet openconnect im Hintergrund mit PID-Datei und Log an root-eigenen Orten.
    static func connect(openconnectPath: String, session: VpnSession, profile: VpnProfile,
                        cookieFilePath: String) -> String? {
        guard Config.openconnectCandidates.contains(openconnectPath),
              isSafePath(cookieFilePath),
              let validSession = VpnSession(cookie: session.cookie, connectUrl: session.connectUrl,
                                            serverFingerprint: session.serverFingerprint)
        else { return nil }

        let log = shellQuoted(Config.tunnelLogPath)
        let openconnect = [
            "/usr/bin/env", "LC_ALL=C", shellQuoted(openconnectPath),
            "--background",
            "--protocol=anyconnect",
            "--pid-file=" + shellQuoted(Config.pidFilePath),
            "--reconnect-timeout=\(Config.reconnectTimeoutSeconds)",
            "--no-system-trust", // Server ist per Zertifikats-Pin festgelegt
            "--cookie-on-stdin",
            "--servercert=" + shellQuoted(validSession.serverFingerprint),
            shellQuoted(validSession.connectUrl),
        ].joined(separator: " ")
        return "umask 022; /bin/rm -f \(log); "
            + "{ echo \(shellQuoted("PROFIL=" + profile.rawValue)); \(openconnect) < \(shellQuoted(cookieFilePath)); }"
            + " > \(log) 2>&1"
    }

    /// Signalisiert genau einen Prozess — und nur, wenn er wirklich openconnect ist.
    static func signal(_ signal: TunnelSignal, pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        return "case $(/bin/ps -p \(pid) -o comm=) in *openconnect) /bin/kill -\(signal.rawValue) \(pid) ;; "
            + "*) echo 'not an openconnect process' >&2; exit 3 ;; esac"
    }

    /// AppleScript-Quelltext für `do shell script … with administrator privileges`.
    static func appleScriptSource(for shellCommand: String) -> String {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Absolute Pfade nur aus harmlosen Zeichen (Temp-Ordner von macOS sehen so aus).
    static func isSafePath(_ path: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/")
        return path.hasPrefix("/") && !path.contains("..") && path.count <= 1024
            && path.allSatisfy { allowed.contains($0) }
    }
}

/// Darf diese Datei/dieser Ordner als Teil einer root-gestarteten Binary gelten?
/// Nicht für alle beschreibbar und entweder root oder dem aktuellen User gehörend.
enum ExecutableTrust {
    struct Item: Equatable {
        let path: String
        let permissions: Int
        let ownerId: UInt32
    }

    static func problems(_ items: [Item], currentUserId: UInt32) -> [String] {
        items.compactMap { item in
            if item.permissions & 0o002 != 0 {
                return L("\(item.path) ist für alle Benutzer beschreibbar.",
                         "\(item.path) is writable by every user.")
            }
            if item.ownerId != 0 && item.ownerId != currentUserId {
                return L("\(item.path) gehört einem anderen Benutzer.",
                         "\(item.path) belongs to a different user.")
            }
            return nil
        }
    }
}
