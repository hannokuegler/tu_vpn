// Tests für die reine Logik in Sources/Core — ohne XCTest, damit sie mit den
// Command Line Tools allein laufen:  ./build.sh test

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        print("FAIL (Tests/main.swift:\(line)): \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    check(actual == expected, "\(message) — erwartet \(expected), bekommen \(actual)", line: line)
}

let validFingerprint = "pin-sha256:" + Data(repeating: 7, count: 32).base64EncodedString()
let validUrl = "https://vpn.tuwien.ac.at/"
let validCookie = "webvpn=ABCDEF0123@12345@1700000000@0123456789ABCDEF"

// MARK: Sprache

checkEqual(AppLanguage.resolve(preferredLanguages: ["de-AT", "en-AT"]), .german, "de-AT → Deutsch")
checkEqual(AppLanguage.resolve(preferredLanguages: ["en-GB", "de-AT"]), .english, "en-GB zuerst → Englisch")
checkEqual(AppLanguage.resolve(preferredLanguages: ["tr-TR"]), .english, "andere Sprache → Englisch")
checkEqual(AppLanguage.resolve(preferredLanguages: []), .english, "keine Angabe → Englisch")

// MARK: Login-Normalisierung

checkEqual(LoginNormalizer.normalize("e12345678"), "e12345678@student.tuwien.ac.at", "e + 8 Ziffern")
checkEqual(LoginNormalizer.normalize(" E 1234 5678 "), "e12345678@student.tuwien.ac.at", "Groß, Leerzeichen")
checkEqual(LoginNormalizer.normalize("12345678"), "e12345678@student.tuwien.ac.at", "nur Matrikelnummer")
checkEqual(LoginNormalizer.normalize("e0725123"), "e0725123@student.tuwien.ac.at", "7-stellig alt mit 0")
checkEqual(LoginNormalizer.normalize("1234567"), "e1234567@student.tuwien.ac.at", "7 Ziffern")
checkEqual(LoginNormalizer.normalize("12345678@student.tuwien.ac.at"), "e12345678@student.tuwien.ac.at",
           "Matrikelnummer mit Domain bekommt e")
checkEqual(LoginNormalizer.normalize("Max.Muster@TUWIEN.ac.at"), "max.muster@tuwien.ac.at", "Mitarbeiter")
checkEqual(LoginNormalizer.normalize("jane@extern.tuwien.ac.at"), "jane@extern.tuwien.ac.at", "extern")
checkEqual(LoginNormalizer.normalize("e12345678@student.tuwien.at"), nil, "Tippfehler in Domain")
checkEqual(LoginNormalizer.normalize("max@gmail.com"), nil, "fremde Domain")
checkEqual(LoginNormalizer.normalize("e123"), nil, "zu kurz")
checkEqual(LoginNormalizer.normalize("e123456789"), nil, "zu lang")
checkEqual(LoginNormalizer.normalize("maxmuster"), nil, "Mitarbeiter ohne Domain")
checkEqual(LoginNormalizer.normalize("a@b@tuwien.ac.at"), nil, "zwei @")
checkEqual(LoginNormalizer.normalize("x';rm@tuwien.ac.at"), nil, "Sonderzeichen")
checkEqual(LoginNormalizer.normalize("   "), nil, "leer")

// MARK: Session-Prüfung

check(VpnSession.isValidFingerprint(validFingerprint), "gültiger Pin")
check(!VpnSession.isValidFingerprint("sha1:" + String(repeating: "a", count: 40)), "falsches Präfix")
check(!VpnSession.isValidFingerprint("pin-sha256:abc"), "zu kurz")
check(!VpnSession.isValidFingerprint("pin-sha256:" + String(repeating: "A", count: 43) + "'"), "Quote im Pin")
check(VpnSession.isValidConnectUrl(validUrl), "Standard-URL")
check(VpnSession.isValidConnectUrl("https://vpn.tuwien.ac.at:443/1_TU_getunnelt"), "mit Port und Pfad")
check(!VpnSession.isValidConnectUrl("http://vpn.tuwien.ac.at/"), "kein https")
check(!VpnSession.isValidConnectUrl("https://vpn.tuwien.ac.at.evil.example/"), "fremder Host")
check(!VpnSession.isValidConnectUrl("https://evil.example/vpn.tuwien.ac.at"), "Host im Pfad")
check(!VpnSession.isValidConnectUrl("https://user@vpn.tuwien.ac.at/"), "User in URL")
check(!VpnSession.isValidConnectUrl("https://vpn.tuwien.ac.at:8443/"), "anderer Port")
check(!VpnSession.isValidConnectUrl("https://vpn.tuwien.ac.at/';reboot;'"), "Shell-Injection")
check(!VpnSession.isValidConnectUrl("https://vpn.tuwien.ac.at/$(id)"), "Command Substitution")
check(VpnSession.isValidCookie(validCookie), "gültiges Cookie")
check(!VpnSession.isValidCookie(""), "leeres Cookie")
check(!VpnSession.isValidCookie("a b"), "Leerzeichen im Cookie")
check(!VpnSession.isValidCookie("abc\ndef"), "Zeilenumbruch im Cookie")
check(!VpnSession.isValidCookie("abc'def"), "Quote im Cookie")

let authenticateOutput = """
POST https://vpn.tuwien.ac.at/
COOKIE='\(validCookie)'
HOST='128.131.240.4'
CONNECT_URL='\(validUrl)'
FINGERPRINT='\(validFingerprint)'
RESOLVE='vpn.tuwien.ac.at:128.131.240.4'
"""
let parsedSession = VpnSession(authenticateOutput: authenticateOutput)
checkEqual(parsedSession?.cookie, validCookie, "Cookie aus --authenticate")
checkEqual(parsedSession?.connectUrl, validUrl, "CONNECT_URL aus --authenticate")
checkEqual(parsedSession?.serverFingerprint, validFingerprint, "FINGERPRINT aus --authenticate")
checkEqual(VpnSession(serialized: parsedSession?.serialized ?? ""), parsedSession, "Schlüsselbund-Rundreise")
check(VpnSession(authenticateOutput: "COOKIE='x'\nCONNECT_URL='https://evil.example/'\nFINGERPRINT='\(validFingerprint)'") == nil,
      "fremde CONNECT_URL wird verworfen")
check(VpnSession(serialized: "\(validCookie)\nhttps://evil.example/\n\(validFingerprint)") == nil,
      "präparierter Schlüsselbund-Eintrag wird verworfen")
check(VpnSession(serialized: "only-one-line") == nil, "kaputter Eintrag")

// MARK: Fehlerbilder

let wrongPasswordLog = """
POST https://vpn.tuwien.ac.at/
Please enter your username and password.
POST https://vpn.tuwien.ac.at/
Login failed.
Password:
fgets (stdin): Inappropriate ioctl for device
"""
let wrongMfaLog = """
POST https://vpn.tuwien.ac.at/
Bitte geben Sie Ihren Zwei-Faktor-Authentifizierungscode ein.
Please enter your two-factor authentication code.
Response:
POST https://vpn.tuwien.ac.at/
Login failed.
"""
checkEqual(FailureClassifier.classify(wrongPasswordLog), .passwordRejected, "Passwort falsch")
checkEqual(FailureClassifier.classify(wrongMfaLog), .mfaRejected, "MFA falsch")
checkEqual(FailureClassifier.classify("getaddrinfo failed for host 'vpn.tuwien.ac.at': nodename nor servname provided, or not known"),
           .noInternet, "DNS")
checkEqual(FailureClassifier.classify("Failed to connect to host vpn.tuwien.ac.at\nFailed to open HTTPS connection to vpn.tuwien.ac.at"),
           .serverUnreachable, "Server nicht erreichbar")
checkEqual(FailureClassifier.classify("Got inappropriate HTTP CONNECT response: HTTP/1.1 401 Unauthorized\nCookie was rejected by server; exiting."),
           .sessionExpired, "Cookie abgelaufen")
checkEqual(FailureClassifier.classify("Server SSL certificate didn't match: pin-sha256:xyz"), .sessionExpired, "Zertifikat gewechselt")
checkEqual(FailureClassifier.classify("Login denied, unauthorized connection mechanism, contact your administrator."),
           .notAuthorized, "keine Berechtigung")
checkEqual(FailureClassifier.classify("Login denied. Simultaneous login limit exceeded."), .sessionLimit, "Session-Limit")
checkEqual(FailureClassifier.classify("something completely different"), .unknown, "Unbekanntes")
checkEqual(FailureClassifier.classify(urlErrorCode: .notConnectedToInternet), .noInternet, "offline")
checkEqual(FailureClassifier.classify(urlErrorCode: .cannotFindHost), .noInternet, "DNS (URLError)")
checkEqual(FailureClassifier.classify(urlErrorCode: .serverCertificateUntrusted), .noInternet, "WLAN-Anmeldeseite")
checkEqual(FailureClassifier.classify(urlErrorCode: .timedOut), .serverUnreachable, "Timeout")
checkEqual(lastLines("a\nb<BR>\nc\n\nd", 2), "c\nd", "letzte Zeilen ohne Banner")

// MARK: Tunnel-Log

let tunnelLog = """
PROFIL=2_Alles_getunnelt
POST https://vpn.tuwien.ac.at/
Configured as 128.131.237.170 + 2001:629:8011::ee/64, with SSL connected and DTLS connected
Session authentication will expire at Sat, 10 Oct 2026 12:39:16 CEST
Continuing in background; pid 57618
"""
let vienna = TimeZone(identifier: "Europe/Vienna")!
let logInfo = TunnelLogInfo.parse(tunnelLog, timeZone: vienna)
checkEqual(logInfo.profile, .everything, "Profil aus Log")
checkEqual(logInfo.address, "128.131.237.170", "IP aus Log")
var viennaCalendar = Calendar(identifier: .gregorian)
viennaCalendar.timeZone = vienna
checkEqual(logInfo.sessionExpiry, viennaCalendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12, minute: 39, second: 16)),
           "Ablaufzeit aus Log")
checkEqual(TunnelLogInfo.parse("Configured as 10.0.0.5, with SSL connected").address, "10.0.0.5", "IP mit Komma")
checkEqual(TunnelLogInfo.parse("PROFIL=3_gibts_nicht").profile, nil, "unbekanntes Profil")

// MARK: root-Befehle

let cookieFile = "/var/folders/ab/xyz_123/T/tuvpn-1234/cookie"
let session = VpnSession(cookie: validCookie, connectUrl: validUrl, serverFingerprint: validFingerprint)!
let connectCommand = RootCommand.connect(openconnectPath: "/opt/homebrew/bin/openconnect", session: session,
                                         profile: .tuOnly, cookieFilePath: cookieFile)
checkEqual(connectCommand,
           "umask 022; /bin/rm -f '/var/log/tuvpn.log'; { echo 'PROFIL=1_TU_getunnelt'; /usr/bin/env LC_ALL=C "
           + "'/opt/homebrew/bin/openconnect' --background --protocol=anyconnect --pid-file='/var/run/tuvpn.pid' "
           + "--reconnect-timeout=86400 --no-system-trust --cookie-on-stdin --servercert='\(validFingerprint)' 'https://vpn.tuwien.ac.at/' "
           + "< '\(cookieFile)'; } > '/var/log/tuvpn.log' 2>&1",
           "Verbinden-Befehl exakt")
check(!(connectCommand ?? "").contains(validCookie), "Cookie steht nie im Befehl")
check(RootCommand.connect(openconnectPath: "/tmp/openconnect", session: session, profile: .tuOnly,
                          cookieFilePath: cookieFile) == nil, "openconnect-Pfad nur aus fester Liste")
check(RootCommand.connect(openconnectPath: "/opt/homebrew/bin/openconnect", session: session, profile: .tuOnly,
                          cookieFilePath: "/tmp/x'; reboot; '") == nil, "Cookie-Pfad mit Quote abgelehnt")
check(RootCommand.connect(openconnectPath: "/opt/homebrew/bin/openconnect", session: session, profile: .tuOnly,
                          cookieFilePath: "/tmp/../etc/master.passwd") == nil, "Cookie-Pfad mit .. abgelehnt")
checkEqual(RootCommand.signal(.disconnectKeepingSession, pid: 4242),
           "case $(/bin/ps -p 4242 -o comm=) in *openconnect) /bin/kill -HUP 4242 ;; *) echo 'not an openconnect process' >&2; exit 3 ;; esac",
           "Trennen signalisiert nur die eigene PID")
check(RootCommand.signal(.logout, pid: 4242)?.contains("/bin/kill -INT 4242") == true, "Abmelden = SIGINT")
check(RootCommand.signal(.logout, pid: 1) == nil, "launchd nie")
check(RootCommand.signal(.logout, pid: -5) == nil, "negative PID nie")
checkEqual(RootCommand.shellQuoted("a'b"), "'a'\\''b'", "Shell-Quoting")
checkEqual(RootCommand.appleScriptSource(for: "echo \"x\" \\ y"),
           "do shell script \"echo \\\"x\\\" \\\\ y\" with administrator privileges", "AppleScript-Escaping")

// MARK: Binary-Prüfung

let me: UInt32 = 501
checkEqual(ExecutableTrust.problems([.init(path: "/opt/homebrew/bin", permissions: 0o775, ownerId: me),
                                     .init(path: "/opt/homebrew/Cellar/openconnect/9.21/bin/openconnect", permissions: 0o555, ownerId: me)],
                                    currentUserId: me).count, 0, "Homebrew-Standard ist ok")
checkEqual(ExecutableTrust.problems([.init(path: "/usr/local/bin/openconnect", permissions: 0o777, ownerId: me)],
                                    currentUserId: me).count, 1, "world-writable wird abgelehnt")
checkEqual(ExecutableTrust.problems([.init(path: "/usr/local/bin/openconnect", permissions: 0o755, ownerId: 502)],
                                    currentUserId: me).count, 1, "fremder Besitzer wird abgelehnt")
checkEqual(ExecutableTrust.problems([.init(path: "/opt/local/sbin/openconnect", permissions: 0o755, ownerId: 0)],
                                    currentUserId: me).count, 0, "root-Besitz ist ok")

// MARK: Ohne Mac-Passwort

let versionFile = "helper=1\nsource=/opt/homebrew/Cellar/openconnect/9.21/bin/openconnect\nopenconnect=OpenConnect version v9.21\n"
let currentSource = "/opt/homebrew/Cellar/openconnect/9.21/bin/openconnect"
checkEqual(Passwordless.evaluate(helperInstalled: false, sudoersInstalled: false, versionFile: nil,
                                 currentOpenconnectSource: currentSource), .off, "nicht eingerichtet")
checkEqual(Passwordless.evaluate(helperInstalled: true, sudoersInstalled: true, versionFile: versionFile,
                                 currentOpenconnectSource: currentSource), .ready, "eingerichtet")
checkEqual(Passwordless.evaluate(helperInstalled: true, sudoersInstalled: true, versionFile: versionFile,
                                 currentOpenconnectSource: nil), .ready, "Homebrew-openconnect weg, Kopie läuft")
checkEqual(Passwordless.evaluate(helperInstalled: true, sudoersInstalled: true, versionFile: versionFile,
                                 currentOpenconnectSource: "/opt/homebrew/Cellar/openconnect/9.22/bin/openconnect"),
           .outdated, "openconnect aktualisiert")
checkEqual(Passwordless.evaluate(helperInstalled: true, sudoersInstalled: true,
                                 versionFile: versionFile.replacingOccurrences(of: "helper=1", with: "helper=0"),
                                 currentOpenconnectSource: currentSource), .outdated, "alter Helper")
checkEqual(Passwordless.evaluate(helperInstalled: true, sudoersInstalled: true, versionFile: nil,
                                 currentOpenconnectSource: currentSource), .outdated, "VERSION fehlt")
checkEqual(Passwordless.evaluate(helperInstalled: true, sudoersInstalled: false, versionFile: versionFile,
                                 currentOpenconnectSource: currentSource), .incomplete, "sudoers fehlt")
checkEqual(Passwordless.evaluate(helperInstalled: false, sudoersInstalled: true, versionFile: nil,
                                 currentOpenconnectSource: currentSource), .incomplete, "Helper fehlt")
let helperSource = (try? String(contentsOfFile: "Helper/tuvpn-helper", encoding: .utf8)) ?? ""
check(helperSource.contains("readonly HELPER_VERSION=\(Passwordless.expectedHelperVersion)\n"),
      "HELPER_VERSION im Shell-Helper passt zur App")
check(helperSource.contains("readonly RECONNECT_TIMEOUT=\(Config.reconnectTimeoutSeconds)\n"),
      "Reconnect-Timeout im Helper passt zur App")

print("\(checkCount - failureCount)/\(checkCount) checks ok")
exit(failureCount == 0 ? 0 : 1)
