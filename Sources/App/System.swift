// Alles, was mit dem System spricht: Prozesse, Schlüsselbund, Admin-Rechte, Tunnel-Erkennung,
// Netzwerk-Vorabprüfung, Mitteilungen. Die Entscheidungslogik dahinter liegt in Sources/Core.

import AppKit
import Darwin
import Security
import UserNotifications

// MARK: - Prozesse

struct ProcessResult {
    let exitCode: Int32
    let output: String
    let errorOutput: String
    let timedOut: Bool
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Startet ein Programm ohne Shell; Geheimnisse gehen nur über stdin, nie über die Argumente.
func runProcess(_ executablePath: String, _ arguments: [String], input: String? = nil,
                timeout: TimeInterval = 30) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C" // englische, auswertbare Meldungen
    environment["LANG"] = "C"
    process.environment = environment

    let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    do {
        try process.run()
    } catch {
        return ProcessResult(exitCode: -1, output: "", errorOutput: error.localizedDescription, timedOut: false)
    }

    // stderr parallel lesen, damit ein voller Puffer nichts blockiert
    let errorBuffer = DataBox()
    let errorReader = DispatchGroup()
    errorReader.enter()
    DispatchQueue.global().async {
        errorBuffer.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        errorReader.leave()
    }
    let startedAt = Date()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

    if let input { try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
    try? inputPipe.fileHandleForWriting.close()
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    errorReader.wait()
    process.waitUntilExit()
    watchdog.cancel()
    let timedOut = process.terminationReason == .uncaughtSignal && Date().timeIntervalSince(startedAt) >= timeout - 1
    return ProcessResult(
        exitCode: process.terminationStatus,
        output: String(decoding: outputData, as: UTF8.self),
        errorOutput: String(decoding: errorBuffer.data, as: UTF8.self),
        timedOut: timedOut)
}

// MARK: - Admin-Rechte (macOS-Passwortdialog)

enum AdminOutcome {
    case success
    case cancelled
    case failed(exitCode: Int, message: String)
}

/// Führt einen Shell-Befehl als root aus — macOS zeigt dafür den Admin-Dialog im Namen von „TU VPN“.
@MainActor
func runAsAdmin(_ shellCommand: String) -> AdminOutcome {
    let script = NSAppleScript(source: RootCommand.appleScriptSource(for: shellCommand))
    var errorInfo: NSDictionary?
    script?.executeAndReturnError(&errorInfo)
    guard let errorInfo else { return .success }
    let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
    if errorNumber == -128 { return .cancelled } // Benutzer hat abgebrochen
    return .failed(exitCode: errorNumber,
                   message: errorInfo[NSAppleScript.errorMessage] as? String ?? L("Unbekannter Fehler", "Unknown error"))
}

// MARK: - openconnect finden und prüfen

func locateOpenconnect() -> String? {
    Config.openconnectCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func isHomebrewInstalled() -> Bool {
    Config.brewCandidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
}

func resolvedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// Probleme mit der openconnect-Binary, bevor sie im Admin-Dialog-Modus als root läuft.
func openconnectTrustProblems(_ path: String) -> [String] {
    let resolved = resolvedPath(path)
    let paths = [(path as NSString).deletingLastPathComponent, resolved, (resolved as NSString).deletingLastPathComponent]
    let items = paths.compactMap { checkedPath -> ExecutableTrust.Item? in
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: checkedPath),
              let permissions = attributes[.posixPermissions] as? Int,
              let owner = attributes[.ownerAccountID] as? NSNumber else { return nil }
        return ExecutableTrust.Item(path: checkedPath, permissions: permissions, ownerId: owner.uint32Value)
    }
    return ExecutableTrust.problems(items, currentUserId: getuid())
}

// MARK: - Modus "Ohne Mac-Passwort"

func currentPasswordlessState() -> PasswordlessState {
    let manager = FileManager.default
    var helperInstalled = false
    if let attributes = try? manager.attributesOfItem(atPath: Passwordless.helperPath),
       let owner = attributes[.ownerAccountID] as? NSNumber, owner.intValue == 0,
       let permissions = attributes[.posixPermissions] as? Int, permissions & 0o022 == 0 {
        helperInstalled = true
    }
    let sudoersInstalled = manager.fileExists(atPath: Passwordless.sudoersPath)
    let versionFile = try? String(contentsOfFile: Passwordless.versionFilePath, encoding: .utf8)
    let source = locateOpenconnect().map(resolvedPath)
    return Passwordless.evaluate(helperInstalled: helperInstalled, sudoersInstalled: sudoersInstalled,
                                 versionFile: versionFile, currentOpenconnectSource: source)
}

/// `sudo -n` sagt so, dass es ein Passwort bräuchte (Regel fehlt oder gilt für einen anderen User).
func sudoNeedsPassword(_ result: ProcessResult) -> Bool {
    let text = result.errorOutput.lowercased()
    return result.exitCode != 0 && (text.contains("password is required") || text.contains("not allowed")
                                    || text.contains("may not run sudo") || text.contains("not in the sudoers"))
}

// MARK: - Schlüsselbund

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(service: String, account: String, value: String) {
        delete(service: service, account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: service,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Ohne account: löscht alle Einträge des Dienstes.
    static func delete(service: String, account: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        while SecItemDelete(query as CFDictionary) == errSecSuccess && account == nil {}
    }
}

// MARK: - Cookie-Datei für den root-Prozess

/// Exklusiv angelegte 0600-Datei in einem frischen 0700-Ordner; `remove()` löscht beides.
struct SecretFile {
    let directory: String
    let path: String

    static func create(_ content: String) -> SecretFile? {
        let directory = NSTemporaryDirectory() + "tuvpn-" + UUID().uuidString
        guard mkdir(directory, 0o700) == 0 else { return nil }
        let path = directory + "/cookie"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { rmdir(directory); return nil }
        let bytes = Array(content.utf8)
        let written = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        let file = SecretFile(directory: directory, path: path)
        guard written == bytes.count else { file.remove(); return nil }
        return file
    }

    func remove() {
        unlink(path)
        rmdir(directory)
    }
}

// MARK: - Laufenden Tunnel erkennen

struct TunnelProcess {
    let pid: Int32
    /// true: über /var/run/tuvpn.pid gefunden · false: alter Start ohne PID-Datei (an der TU-Adresse erkannt)
    let fromPidFile: Bool
    let profileFromArguments: VpnProfile?

    /// Der TU-Tunnel: zuerst die root-eigene PID-Datei, sonst ein openconnect, das mit vpn.tuwien.ac.at verbunden ist.
    static func find() -> TunnelProcess? {
        if let pid = pidFromPidFile(), isOpenconnect(pid) {
            return TunnelProcess(pid: pid, fromPidFile: true, profileFromArguments: nil)
        }
        for pid in openconnectPids() {
            let arguments = processArguments(pid)
            guard arguments.contains(Config.vpnServer) else { continue }
            let profile = VpnProfile.allCases.first { arguments.contains("--authgroup=" + $0.rawValue) }
            return TunnelProcess(pid: pid, fromPidFile: false, profileFromArguments: profile)
        }
        return nil
    }

    /// openconnect-Prozesse, die nicht zum TU-Tunnel gehören (z. B. ein anderes VPN).
    static func foreignOpenconnectPids() -> [Int32] {
        let tunnelPid = find()?.pid
        return openconnectPids().filter { $0 != tunnelPid }
    }

    static func isRunning(_ pid: Int32) -> Bool { isOpenconnect(pid) }

    private static func pidFromPidFile() -> Int32? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: Config.pidFilePath),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              attributes[.type] as? FileAttributeType == .typeRegular,
              let content = try? String(contentsOfFile: Config.pidFilePath, encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }

    private static func isOpenconnect(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasSuffix("/openconnect")
    }

    private static func openconnectPids() -> [Int32] {
        runProcess("/usr/bin/pgrep", ["-x", "openconnect"]).output
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func processArguments(_ pid: Int32) -> String {
        runProcess("/bin/ps", ["-o", "args=", "-p", String(pid)]).output
    }
}

// MARK: - Status

struct VpnStatus {
    var tunnel: TunnelProcess?
    var info = TunnelLogInfo()

    var isConnected: Bool { tunnel != nil }
    var profile: VpnProfile? { info.profile ?? tunnel?.profileFromArguments }

    static func read() -> VpnStatus {
        var status = VpnStatus()
        status.tunnel = TunnelProcess.find()
        if let tunnel = status.tunnel, tunnel.fromPidFile, let log = readTunnelLog() {
            status.info = TunnelLogInfo.parse(log)
        }
        return status
    }
}

func readTunnelLog() -> String? {
    guard let data = FileManager.default.contents(atPath: Config.tunnelLogPath) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Netzwerk-Vorabprüfung

/// Kurzer HTTPS-Aufruf an vpn.tuwien.ac.at, bevor nach Passwort, MFA oder Admin-Rechten gefragt wird.
func checkServerReachable() async -> VpnFailure? {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Config.reachabilityTimeoutSeconds
    configuration.timeoutIntervalForResource = Config.reachabilityTimeoutSeconds
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "https://\(Config.vpnServer)/")!)
    request.httpMethod = "HEAD"
    do {
        _ = try await session.data(for: request)
        return nil
    } catch let error as URLError {
        let failure = FailureClassifier.classify(urlErrorCode: error.code)
        return failure == .unknown ? nil : failure // Unklares nicht blockieren, openconnect sagt es genauer
    } catch {
        return nil
    }
}

// MARK: - Mitteilungen

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
