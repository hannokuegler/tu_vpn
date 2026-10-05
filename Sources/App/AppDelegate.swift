// TU VPN — Menüleisten-App fürs TUvpn der TU Wien (inoffiziell), baut auf openconnect auf.
//
// Login (Netzwerkpasswort + MFA) nur einmal pro TU-Session (~5 Tage): das Session-Cookie liegt im
// Schlüsselbund. "Trennen" lässt die Session beim Server offen (SIGHUP), "Abmelden" beendet sie
// (SIGINT). Den Tunnel startet root — entweder über den macOS-Admin-Dialog oder, wenn eingerichtet,
// passwortlos über den root-eigenen Helper in /Library/TUvpn (siehe SECURITY.md).

import AppKit
import ServiceManagement

enum TunnelOutcome {
    case connected
    case cancelled
    case failed(VpnFailure, String)
}

enum AuthResult {
    case success(VpnSession)
    case failure(VpnFailure, String)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let defaults = UserDefaults.standard
    private var status = VpnStatus()
    private var isBusy = false
    private var busyText = ""
    private var isUserDisconnecting = false
    private var lastWake: Date?
    private var lastDropNote: String?
    /// sudo hat in dieser Sitzung ein Passwort verlangt → bis zum Neueinrichten den Admin-Dialog nehmen.
    private var passwordlessBroken = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacySettings()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshStatus()
        Timer.scheduledTimer(timeInterval: Config.statusRefreshSeconds, target: self,
                             selector: #selector(refreshStatus), userInfo: nil, repeats: true)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        if defaults.string(forKey: Config.userDefaultsKey) == nil && !defaults.bool(forKey: Config.onboardingDoneKey) {
            DispatchQueue.main.async { self.runOnboarding() }
        }
    }

    /// Doppelklick auf die schon laufende App: Menü aufklappen, damit man sie findet.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
    }

    private func migrateLegacySettings() {
        guard defaults.string(forKey: Config.userDefaultsKey) == nil,
              let legacyUser = UserDefaults(suiteName: Config.legacyDefaultsDomain)?.string(forKey: Config.userDefaultsKey)
        else { return }
        defaults.set(legacyUser, forKey: Config.userDefaultsKey)
        defaults.set(true, forKey: Config.onboardingDoneKey)
    }

    // MARK: - Status

    @objc private func refreshStatus() {
        guard !isBusy else { return }
        let newStatus = VpnStatus.read()
        if status.isConnected && !newStatus.isConnected && !isUserDisconnecting {
            handleUnexpectedDrop(previous: status)
        }
        if newStatus.isConnected { lastDropNote = nil }
        status = newStatus
        updateStatusButton()
    }

    @objc private func systemDidWake() {
        lastWake = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.refreshStatus() }
    }

    private func setBusy(_ busy: Bool, _ text: String = "") {
        isBusy = busy
        busyText = text
        if !busy {
            status = VpnStatus.read()
            if status.isConnected { lastDropNote = nil }
        }
        updateStatusButton()
    }

    /// Kurz den Runloop drehen, damit „TU…“ gezeichnet ist, bevor ein blockierender Admin-Dialog kommt.
    private func letMenuBarRedraw() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        // Bewusst nur Text: "TU" kräftig = verbunden ("TU+" = alles getunnelt), blass = getrennt, "TU…" = beschäftigt
        let title: String
        let textColor: NSColor
        if isBusy {
            title = "TU…"
            textColor = .secondaryLabelColor
            button.toolTip = busyText
        } else if status.isConnected {
            title = status.profile?.statusBarTitle ?? "TU"
            textColor = .labelColor
            button.toolTip = L("TU VPN verbunden", "TU VPN connected")
        } else {
            title = "TU"
            textColor = .tertiaryLabelColor
            button.toolTip = L("TU VPN nicht verbunden", "TU VPN not connected")
        }
        button.image = nil
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: textColor,
        ])
    }

    private func handleUnexpectedDrop(previous: VpnStatus) {
        let log = previous.tunnel?.fromPidFile == true ? lastLines(readTunnelLog() ?? "", 15) : ""
        let sessionEnded = FailureClassifier.classify(log) == .sessionExpired
            || log.lowercased().contains("session terminated by server")
        var body: String
        if sessionEnded {
            Keychain.delete(service: Config.sessionKeychainService, account: previous.profile?.rawValue)
            body = L("Die TU-Session ist abgelaufen oder wurde beendet. Beim nächsten Verbinden fragt TU VPN wieder nach Passwort und MFA-Code.",
                     "The TU session expired or was ended. Next time you connect, TU VPN asks for your password and MFA code again.")
        } else if let lastWake, Date().timeIntervalSince(lastWake) < 300 {
            body = L("Nach dem Ruhezustand ließ sich der Tunnel nicht wiederherstellen. Einfach im Menü neu verbinden.",
                     "The tunnel could not be restored after sleep. Just reconnect from the menu.")
        } else {
            body = L("Die Verbindung ist abgebrochen. Einfach im Menü neu verbinden.",
                     "The connection dropped. Just reconnect from the menu.")
        }
        body += "\n" + L("Log", "Log") + ": " + Config.tunnelLogPath
        lastDropNote = L("Getrennt um ", "Disconnected at ") + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        Notifier.post(title: L("TU VPN getrennt", "TU VPN disconnected"), body: body)
    }

    // MARK: - Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatus()
        menu.removeAllItems()

        if isBusy {
            addInfoItem(busyText)
        } else if status.isConnected {
            addInfoItem(L("● Verbunden", "● Connected") + (status.profile.map { " – \($0.menuTitle)" } ?? ""))
            if let address = status.info.address { addInfoItem(L("IP-Adresse: ", "IP address: ") + address) }
            if let expiry = status.info.sessionExpiry {
                addInfoItem(L("Session gültig bis ", "Session valid until ") + formatExpiry(expiry))
            }
            addInfoItem(L("Darf ruhig an bleiben – Trennen nur zum Profilwechsel", "Fine to leave on – disconnect only to switch profiles"))
            menu.addItem(.separator())
            addActionItem(L("Trennen", "Disconnect"), #selector(disconnectKeepingSession),
                          toolTip: L("Tunnel zu, Session bleibt beim Server offen – nächstes Verbinden ohne Passwort und MFA.",
                                     "Closes the tunnel but keeps the session – reconnect without password and MFA."))
            addActionItem(L("Abmelden (Session beenden)", "Log out (end session)"), #selector(disconnectEndingSession),
                          toolTip: L("Beendet die Session beim Server – nötig vor einem Profilwechsel.",
                                     "Ends the session on the server – needed before switching profiles."))
        } else {
            addInfoItem(L("○ Nicht verbunden", "○ Not connected"))
            if let lastDropNote { addInfoItem(lastDropNote) }
            menu.addItem(.separator())
            for profile in VpnProfile.allCases {
                let item = addActionItem(L("Verbinden – ", "Connect – ") + profile.menuTitle,
                                         #selector(connectFromMenu(_:)), toolTip: profile.explanation)
                item.representedObject = profile.rawValue
            }
        }

        menu.addItem(.separator())
        if let user = defaults.string(forKey: Config.userDefaultsKey) {
            addInfoItem(L("Account: ", "Account: ") + user)
        } else {
            addActionItem(L("Einrichten …", "Set up …"), #selector(runOnboardingFromMenu))
        }
        addPasswordlessItem()
        let launchItem = addActionItem(L("Bei Anmeldung starten", "Open at login"), #selector(toggleLaunchAtLogin))
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        addActionItem(L("Hängende Sessions beenden …", "End stale sessions …"), #selector(openSessionsPortal),
                      toolTip: L("Max. 3 gleichzeitige Sessions pro Account – hier lassen sich alte beenden.",
                                 "Max. 3 simultaneous sessions per account – end old ones here."))

        let helpMenu = NSMenu()
        helpMenu.autoenablesItems = false
        if defaults.string(forKey: Config.userDefaultsKey) != nil {
            addActionItem(L("Login-Daten löschen …", "Forget login data …"), #selector(forgetLoginData), to: helpMenu)
        }
        addActionItem(L("Anmelde-Log öffnen", "Open login log"), #selector(openAuthLog), to: helpMenu)
        addActionItem(L("Tunnel-Log öffnen", "Open tunnel log"), #selector(openTunnelLog), to: helpMenu)
        addActionItem(L("Hilfe & Updates (GitHub)", "Help & updates (GitHub)"), #selector(openProjectPage), to: helpMenu)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let versionItem = NSMenuItem(title: "TU VPN \(version) – " + L("inoffiziell", "unofficial"), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        helpMenu.addItem(versionItem)
        let helpItem = NSMenuItem(title: L("Weitere", "More"), action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        menu.addItem(.separator())
        let quitItem = addActionItem(L("TU VPN beenden", "Quit TU VPN"), #selector(NSApplication.terminate(_:)),
                                     toolTip: L("Beendet nur die App – eine laufende VPN-Verbindung bleibt bestehen.",
                                                "Quits only the app – a running VPN connection stays up."))
        quitItem.target = NSApp
        quitItem.keyEquivalent = "q"
    }

    private func addPasswordlessItem() {
        let state = currentPasswordlessState()
        let title: String
        switch state {
        case .off, .ready:
            title = L("Ohne Mac-Passwort verbinden", "Connect without Mac password")
        case .outdated:
            title = L("Ohne Mac-Passwort: neu einrichten (openconnect aktualisiert) …",
                      "Without Mac password: set up again (openconnect updated) …")
        case .incomplete:
            title = L("Ohne Mac-Passwort: unvollständig – reparieren …", "Without Mac password: incomplete – repair …")
        }
        let item = addActionItem(title, #selector(managePasswordless),
                                 toolTip: L("Mac-Passwort nur einmal beim Einrichten eingeben – danach Verbinden/Trennen ohne Abfrage.",
                                            "Enter your Mac password once during setup – then connect/disconnect without prompts."))
        item.state = state == .ready ? .on : .off
    }

    private func formatExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current == .german ? "de_AT" : "en_GB")
        formatter.dateFormat = AppLanguage.current == .german ? "EEE d.M., HH:mm" : "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }

    private func addInfoItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addActionItem(_ title: String, _ action: Selector, toolTip: String? = nil, to targetMenu: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.toolTip = toolTip
        (targetMenu ?? menu).addItem(item)
        return item
    }

    // MARK: - Erststart

    @objc private func runOnboardingFromMenu() { runOnboarding() }

    private func runOnboarding() {
        defaults.set(true, forKey: Config.onboardingDoneKey)
        guard let (_, startAtLogin) = askLogin(welcome: true) else { return }
        if startAtLogin && SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        connect(.tuOnly)
    }

    // MARK: - Verbinden

    @objc private func connectFromMenu(_ sender: NSMenuItem) {
        guard let rawProfile = sender.representedObject as? String,
              let profile = VpnProfile(rawValue: rawProfile) else { return }
        connect(profile)
    }

    private func usePasswordless() -> Bool {
        let state = currentPasswordlessState()
        return (state == .ready || state == .outdated) && !passwordlessBroken
    }

    private func connect(_ profile: VpnProfile) {
        guard !isBusy else { return }
        let viaHelper = usePasswordless()
        let homebrewOpenconnect = locateOpenconnect()
        // Für die Anmeldung (läuft als User) reicht notfalls auch die root-eigene Kopie.
        let authOpenconnect = homebrewOpenconnect
            ?? (viaHelper ? Passwordless.installDir + "/bin/openconnect" : nil)
        guard let authOpenconnect else { showMissingOpenconnect(); return }
        if !viaHelper, let homebrewOpenconnect {
            let problems = openconnectTrustProblems(homebrewOpenconnect)
            guard problems.isEmpty else { showUnsafeOpenconnect(problems); return }
        }
        guard let user = configuredUser() else { return }
        let foreignPids = TunnelProcess.foreignOpenconnectPids()
        if !foreignPids.isEmpty && !confirmForeignVpn(foreignPids) { return }

        setBusy(true, L("Prüfe Netzwerk …", "Checking network …"))
        Task {
            if let failure = await checkServerReachable() {
                setBusy(false)
                showFailure(failure, details: "", logPath: nil, profile: profile)
                return
            }

            // 1. Offene Session wiederverwenden — kein Passwort, kein MFA
            if let savedData = Keychain.read(service: Config.sessionKeychainService, account: profile.rawValue),
               let savedSession = VpnSession(serialized: savedData) {
                setBusy(true, L("Verbinde mit offener Session …", "Connecting with open session …"))
                switch await startTunnel(savedSession, profile, homebrewOpenconnect) {
                case .connected:
                    didConnect()
                    return
                case .cancelled:
                    setBusy(false)
                    return
                case .failed(.sessionExpired, _):
                    // Session abgelaufen → still neu einloggen
                    Keychain.delete(service: Config.sessionKeychainService, account: profile.rawValue)
                case .failed(let failure, let details):
                    setBusy(false)
                    showFailure(failure, details: details, logPath: Config.tunnelLogPath, profile: profile)
                    return
                }
            }

            // 2. Neu einloggen: Netzwerkpasswort + MFA → Session-Cookie
            await loginAndConnect(user: user, profile: profile, authOpenconnect: authOpenconnect,
                                  tunnelOpenconnect: homebrewOpenconnect)
        }
    }

    private func loginAndConnect(user: String, profile: VpnProfile, authOpenconnect: String,
                                 tunnelOpenconnect: String?) async {
        guard let password = networkPassword(for: user), let mfaCode = askMfaCode() else {
            setBusy(false)
            return
        }
        setBusy(true, L("Melde an …", "Signing in …"))
        let authResult = await Task.detached {
            Self.authenticate(user: user, password: password, mfaCode: mfaCode, profile: profile,
                              openconnectPath: authOpenconnect)
        }.value

        switch authResult {
        case .success(let session):
            // Sofort merken — die Session gilt beim Server auch, wenn der Tunnel-Start abgebrochen wird
            Keychain.write(service: Config.sessionKeychainService, account: profile.rawValue, value: session.serialized)
            setBusy(true, L("Verbinde …", "Connecting …"))
            switch await startTunnel(session, profile, tunnelOpenconnect) {
            case .connected:
                didConnect()
            case .cancelled:
                setBusy(false)
            case .failed(let failure, let details):
                setBusy(false)
                showFailure(failure == .sessionExpired ? .unknown : failure, details: details,
                            logPath: Config.tunnelLogPath, profile: profile)
            }
        case .failure(let failure, let details):
            setBusy(false)
            showFailure(failure, details: details, logPath: Config.authLogPath, profile: profile)
        }
    }

    nonisolated private static func authenticate(user: String, password: String, mfaCode: String,
                                                 profile: VpnProfile, openconnectPath: String) -> AuthResult {
        let result = runProcess(openconnectPath, [
            "--authenticate", "--protocol=anyconnect", "--authgroup=\(profile.rawValue)",
            "--user=\(user)", "--passwd-on-stdin", Config.vpnServer,
        ], input: "\(password)\n\(mfaCode)\n", timeout: Config.authTimeoutSeconds)
        writeAuthLog(result.errorOutput)

        if result.timedOut { return .failure(.timeout, "") }
        let details = lastLines(result.errorOutput, 6)
        if result.exitCode == 0 {
            if let session = VpnSession(authenticateOutput: result.output) { return .success(session) }
            return .failure(.unknown, L("Der Server hat unerwartete Session-Daten geliefert.",
                                        "The server returned unexpected session data."))
        }
        return .failure(FailureClassifier.classify(result.errorOutput), details)
    }

    /// stderr von `openconnect --authenticate` (enthält keine Geheimnisse) — nur für den User lesbar.
    nonisolated private static func writeAuthLog(_ text: String) {
        let directory = (Config.authLogPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Config.authLogPath, contents: Data(text.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    /// Baut den Tunnel als root: passwortlos über den Helper, sonst über den Admin-Dialog.
    private func startTunnel(_ session: VpnSession, _ profile: VpnProfile, _ homebrewOpenconnect: String?) async -> TunnelOutcome {
        if usePasswordless() {
            let input = session.serialized + "\n"
            let result = await Task.detached {
                runProcess("/usr/bin/sudo", ["-n", Passwordless.helperPath, "connect", profile.rawValue],
                           input: input, timeout: 120)
            }.value
            if result.exitCode == 0 { return .connected }
            if sudoNeedsPassword(result) {
                passwordlessBroken = true // weiter mit dem Admin-Dialog
            } else if [64, 65, 69, 75, 77].contains(result.exitCode) {
                // Helper hat abgelehnt, bevor openconnect lief → Log wäre veraltet
                return .failed(.unknown, result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                return tunnelFailure(exitCode: Int(result.exitCode), fallbackMessage: result.errorOutput)
            }
        }

        guard let homebrewOpenconnect else {
            return .failed(.unknown, L("openconnect fehlt: brew install openconnect", "openconnect missing: brew install openconnect"))
        }
        guard let cookieFile = SecretFile.create(session.cookie + "\n") else {
            return .failed(.unknown, L("Temporäre Datei konnte nicht angelegt werden.", "Could not create a temporary file."))
        }
        defer { cookieFile.remove() }
        guard let command = RootCommand.connect(openconnectPath: homebrewOpenconnect, session: session,
                                                profile: profile, cookieFilePath: cookieFile.path) else {
            return .failed(.sessionExpired, "")
        }
        await letMenuBarRedraw()
        switch runAsAdmin(command) {
        case .success: return .connected
        case .cancelled: return .cancelled
        case .failed(let exitCode, let message): return tunnelFailure(exitCode: exitCode, fallbackMessage: message)
        }
    }

    private func tunnelFailure(exitCode: Int, fallbackMessage: String) -> TunnelOutcome {
        let log = readTunnelLog() ?? ""
        let failure = exitCode == 2 ? .sessionExpired : FailureClassifier.classify(log) // 2 = Cookie abgelehnt
        let details = lastLines(log, 6)
        return .failed(failure, details.isEmpty ? fallbackMessage : details)
    }

    private func didConnect() {
        setBusy(false)
        lastDropNote = nil
        Notifier.requestPermission() // erst jetzt fragen, wenn es Sinn ergibt
    }

    // MARK: - Trennen

    @objc private func disconnectKeepingSession() { disconnect(endSession: false) }
    @objc private func disconnectEndingSession() { disconnect(endSession: true) }

    private func disconnect(endSession: Bool) {
        guard !isBusy, let tunnel = TunnelProcess.find() else { refreshStatus(); return }
        let connectedProfile = status.profile
        let signal: TunnelSignal = endSession ? .logout : .disconnectKeepingSession
        isUserDisconnecting = true
        setBusy(true, L("Trenne …", "Disconnecting …"))
        Task {
            var outcome: AdminOutcome?
            if tunnel.fromPidFile && usePasswordless() {
                let mode = endSession ? "int" : "hup"
                let result = await Task.detached {
                    runProcess("/usr/bin/sudo", ["-n", Passwordless.helperPath, "disconnect", mode])
                }.value
                if result.exitCode == 0 {
                    outcome = .success
                } else if sudoNeedsPassword(result) {
                    passwordlessBroken = true
                } else {
                    outcome = .failed(exitCode: Int(result.exitCode), message: result.errorOutput)
                }
            }
            if outcome == nil {
                guard let command = RootCommand.signal(signal, pid: tunnel.pid) else { return }
                await letMenuBarRedraw()
                outcome = runAsAdmin(command)
            }

            switch outcome {
            case .cancelled:
                isUserDisconnecting = false
                setBusy(false)
                return
            case .failed(_, let message):
                isUserDisconnecting = false
                setBusy(false)
                showError(L("Trennen fehlgeschlagen.", "Disconnecting failed."), details: message)
                return
            default:
                break
            }
            if endSession {
                Keychain.delete(service: Config.sessionKeychainService, account: connectedProfile?.rawValue)
            }
            for _ in 0..<40 where TunnelProcess.isRunning(tunnel.pid) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            setBusy(false)
            isUserDisconnecting = false
        }
    }

    // MARK: - Ohne Mac-Passwort

    @objc private func managePasswordless() {
        switch currentPasswordlessState() {
        case .off:
            let alert = NSAlert()
            alert.messageText = L("Ohne Mac-Passwort verbinden?", "Connect without your Mac password?")
            alert.informativeText = L(
                "Einmal mit deinem Mac-Passwort einrichten – danach verbindet und trennt TU VPN ohne Passwortabfrage.\n\nDafür legt TU VPN eine geschützte Kopie von openconnect unter /Library/TUvpn an und erlaubt nur deinem Benutzer, genau zwei Dinge ohne Passwort zu tun: das TU-VPN verbinden und trennen. Jederzeit hier im Menü wieder entfernbar.",
                "Set it up once with your Mac password – after that TU VPN connects and disconnects without asking.\n\nTU VPN puts a protected copy of openconnect into /Library/TUvpn and allows only your user to do exactly two things without a password: connect and disconnect the TU VPN. You can remove it here in the menu at any time.")
            alert.addButton(withTitle: L("Einrichten", "Set up"))
            alert.addButton(withTitle: L("Abbrechen", "Cancel"))
            alert.addButton(withTitle: L("Details (Sicherheit)", "Details (security)"))
            switch present(alert) {
            case .alertFirstButtonReturn: setUpPasswordless()
            case .alertThirdButtonReturn: NSWorkspace.shared.open(Config.projectUrl.appendingPathComponent("blob/main/SECURITY.md"))
            default: break
            }
        case .ready:
            let alert = NSAlert()
            alert.messageText = L("Passwortlosen Modus entfernen?", "Remove passwordless mode?")
            alert.informativeText = L("Danach fragt TU VPN beim Verbinden und Trennen wieder nach deinem Mac-Passwort.",
                                      "TU VPN will ask for your Mac password again when connecting and disconnecting.")
            alert.addButton(withTitle: L("Entfernen", "Remove"))
            alert.addButton(withTitle: L("Abbrechen", "Cancel"))
            if present(alert) == .alertFirstButtonReturn { removePasswordless() }
        case .outdated, .incomplete:
            let alert = NSAlert()
            alert.messageText = L("Passwortlosen Modus neu einrichten?", "Set up passwordless mode again?")
            alert.informativeText = L(
                "openconnect wurde aktualisiert (oder die Einrichtung ist unvollständig). Neu einrichten übernimmt die aktuelle Version in die geschützte Kopie.",
                "openconnect was updated (or the setup is incomplete). Setting it up again copies the current version into the protected location.")
            alert.addButton(withTitle: L("Neu einrichten", "Set up again"))
            alert.addButton(withTitle: L("Abbrechen", "Cancel"))
            alert.addButton(withTitle: L("Entfernen", "Remove"))
            switch present(alert) {
            case .alertFirstButtonReturn: setUpPasswordless()
            case .alertThirdButtonReturn: removePasswordless()
            default: break
            }
        }
    }

    private func setUpPasswordless() {
        guard locateOpenconnect() != nil else { showMissingOpenconnect(); return }
        guard let setupScript = Bundle.main.path(forResource: "tuvpn-setup", ofType: "sh") else {
            showError(L("Einrichtung nicht möglich.", "Setup not possible."), details: "tuvpn-setup.sh missing in app bundle")
            return
        }
        let command = "/bin/bash -p " + RootCommand.shellQuoted(setupScript) + " install " + RootCommand.shellQuoted(NSUserName())
        setBusy(true, L("Richte ein …", "Setting up …"))
        Task {
            await letMenuBarRedraw()
            let outcome = runAsAdmin(command)
            setBusy(false)
            switch outcome {
            case .success:
                passwordlessBroken = false
                showInfo(L("Fertig – ab jetzt ohne Mac-Passwort.", "Done – no more Mac password prompts."),
                         details: L("Entfernen kannst du es jederzeit im Menü unter „Ohne Mac-Passwort verbinden“.",
                                    "You can remove it any time via “Connect without Mac password” in the menu."))
            case .cancelled:
                break
            case .failed(_, let message):
                showError(L("Einrichtung fehlgeschlagen.", "Setup failed."), details: message)
            }
        }
    }

    private func removePasswordless() {
        let command = "/bin/rm -f " + RootCommand.shellQuoted(Passwordless.sudoersPath)
            + "; /bin/rm -rf " + RootCommand.shellQuoted(Passwordless.installDir)
        setBusy(true, L("Entferne …", "Removing …"))
        Task {
            await letMenuBarRedraw()
            let outcome = runAsAdmin(command)
            setBusy(false)
            if case .failed(_, let message) = outcome {
                showError(L("Entfernen fehlgeschlagen.", "Removing failed."), details: message)
            }
        }
    }

    // MARK: - Login-Daten

    private func configuredUser() -> String? {
        if let savedUser = defaults.string(forKey: Config.userDefaultsKey) { return savedUser }
        return askLogin(welcome: false)?.user
    }

    /// Fragt den TU-Login ab (im Willkommensdialog zusätzlich den Autostart) und speichert ihn.
    private func askLogin(welcome: Bool) -> (user: String, startAtLogin: Bool)? {
        let loginHelp = L("Dein TU-Login:\n• Studierende: e + Matrikelnummer (z. B. e12345678)\n• Mitarbeiter_innen: volle Adresse (name@tuwien.ac.at)",
                          "Your TU login:\n• Students: e + matriculation number (e.g. e12345678)\n• Staff: full address (name@tuwien.ac.at)")
        var message = welcome
            ? L("TU VPN sitzt oben rechts in der Menüleiste („TU“). Ein Klick darauf verbindet und trennt.\n\n",
                "TU VPN lives in the menu bar at the top right (“TU”). Click it to connect and disconnect.\n\n") + loginHelp
            : loginHelp
        while true {
            let alert = NSAlert()
            alert.messageText = welcome ? L("Willkommen bei TU VPN", "Welcome to TU VPN") : L("TU-Login", "TU login")
            alert.informativeText = message
            alert.addButton(withTitle: welcome ? L("Speichern & verbinden", "Save & connect") : L("Weiter", "Continue"))
            alert.addButton(withTitle: welcome ? L("Später", "Later") : L("Abbrechen", "Cancel"))

            let loginField = NSTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
            loginField.placeholderString = "e12345678"
            let startAtLoginBox = NSButton(checkboxWithTitle: L("Beim Anmelden am Mac starten", "Open at login"),
                                           target: nil, action: nil)
            startAtLoginBox.state = .on
            startAtLoginBox.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: welcome ? 56 : 24))
            if welcome {
                container.addSubview(loginField)
                container.addSubview(startAtLoginBox)
            } else {
                loginField.frame.origin.y = 0
                container.addSubview(loginField)
            }
            alert.accessoryView = container
            alert.window.initialFirstResponder = loginField

            guard present(alert) == .alertFirstButtonReturn else { return nil }
            if let user = LoginNormalizer.normalize(loginField.stringValue) {
                defaults.set(user, forKey: Config.userDefaultsKey)
                return (user, welcome && startAtLoginBox.state == .on)
            }
            message = L("„\(loginField.stringValue)“ ist kein gültiger TU-Login.\n\n",
                        "“\(loginField.stringValue)” is not a valid TU login.\n\n") + loginHelp
        }
    }

    private func networkPassword(for user: String) -> String? {
        if let savedPassword = Keychain.read(service: Config.passwordKeychainService, account: user) { return savedPassword }

        let alert = NSAlert()
        alert.messageText = L("TU-Netzwerkpasswort", "TU network password")
        alert.informativeText = L("Für \(user) – das Netzwerkpasswort, nicht das TISS-Passwort.",
                                  "For \(user) – your network password, not your TISS password.")
        alert.addButton(withTitle: L("Weiter", "Continue"))
        alert.addButton(withTitle: L("Abbrechen", "Cancel"))
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = passwordField
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Im Schlüsselbund merken", "Remember in Keychain")
        alert.suppressionButton?.state = .on
        alert.window.initialFirstResponder = passwordField

        guard present(alert) == .alertFirstButtonReturn, !passwordField.stringValue.isEmpty else { return nil }
        if alert.suppressionButton?.state == .on {
            Keychain.write(service: Config.passwordKeychainService, account: user, value: passwordField.stringValue)
        }
        return passwordField.stringValue
    }

    private func askMfaCode() -> String? {
        var message = L("Der sechsstellige Code aus deiner Authenticator-App.", "The six-digit code from your authenticator app.")
        while true {
            let alert = NSAlert()
            alert.messageText = L("MFA-Code", "MFA code")
            alert.informativeText = message
            alert.addButton(withTitle: L("Verbinden", "Connect"))
            alert.addButton(withTitle: L("Abbrechen", "Cancel"))
            let codeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            codeField.placeholderString = "123456"
            alert.accessoryView = codeField
            alert.window.initialFirstResponder = codeField
            guard present(alert) == .alertFirstButtonReturn else { return nil }
            let mfaCode = codeField.stringValue.filter { !$0.isWhitespace }
            if mfaCode.count == 6 && mfaCode.allSatisfy({ $0.isASCII && $0.isNumber }) { return mfaCode }
            message = L("Das waren keine 6 Ziffern – nochmal:", "That was not 6 digits – try again:")
        }
    }

    @objc private func forgetLoginData() {
        let alert = NSAlert()
        alert.messageText = L("Login-Daten löschen?", "Forget login data?")
        alert.informativeText = L("Entfernt Account, gespeichertes Passwort und offene Sessions aus dem Schlüsselbund. Beim nächsten Verbinden fragt die App alles neu ab.",
                                  "Removes account, saved password and open sessions from the Keychain. The app asks for everything again next time.")
        alert.addButton(withTitle: L("Löschen", "Forget"))
        alert.addButton(withTitle: L("Abbrechen", "Cancel"))
        guard present(alert) == .alertFirstButtonReturn else { return }
        if let user = defaults.string(forKey: Config.userDefaultsKey) {
            Keychain.delete(service: Config.passwordKeychainService, account: user)
        }
        Keychain.delete(service: Config.sessionKeychainService)
        defaults.removeObject(forKey: Config.userDefaultsKey)
    }

    // MARK: - Sonstiges

    @objc private func openSessionsPortal() { NSWorkspace.shared.open(Config.sessionsPortalUrl) }
    @objc private func openProjectPage() { NSWorkspace.shared.open(Config.projectUrl) }
    @objc private func openAuthLog() { openLog(Config.authLogPath) }
    @objc private func openTunnelLog() { openLog(Config.tunnelLogPath) }

    private func openLog(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            showInfo(L("Noch kein Log vorhanden.", "No log yet."), details: path)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(L("Autostart konnte nicht geändert werden.", "Could not change open-at-login."),
                      details: error.localizedDescription)
        }
    }

    // MARK: - Dialoge

    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func showError(_ headline: String, details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = headline
        alert.informativeText = details.isEmpty
            ? L("Logs: ", "Logs: ") + "\(Config.authLogPath), \(Config.tunnelLogPath)"
            : details
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    private func showInfo(_ headline: String, details: String) {
        let alert = NSAlert()
        alert.messageText = headline
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    /// Ein Dialog je Fehlerbild — mit verständlichem Text und dem nächsten Schritt als Knopf.
    private func showFailure(_ failure: VpnFailure, details: String, logPath: String?, profile: VpnProfile) {
        let user = defaults.string(forKey: Config.userDefaultsKey) ?? ""
        enum Action { case retry, reenterPassword, openPortal, openAccountHelp, openLog, openHelp, none }
        var title: String
        var text: String
        var buttons: [(String, Action)]
        let retry = (L("Nochmal versuchen", "Try again"), Action.retry)
        let ok = ("OK", Action.none)
        let cancel = (L("Abbrechen", "Cancel"), Action.none)
        let showLog = (L("Log öffnen", "Open log"), Action.openLog)

        switch failure {
        case .noInternet:
            title = L("Keine Internetverbindung", "No internet connection")
            text = L("TU VPN erreicht vpn.tuwien.ac.at nicht. Prüf WLAN oder Kabel. In Hotel-, Zug- oder Gast-WLANs zuerst im Browser auf der Anmeldeseite einloggen.",
                     "TU VPN can't reach vpn.tuwien.ac.at. Check Wi-Fi or cable. On hotel, train or guest Wi-Fi, log in on the portal page in your browser first.")
            buttons = [retry, ok]
        case .serverUnreachable:
            title = L("TU-VPN-Server antwortet nicht", "TU VPN server not responding")
            text = L("vpn.tuwien.ac.at ist gerade nicht erreichbar oder dieses Netz blockiert VPN. Probier's in ein paar Minuten nochmal oder in einem anderen Netz (z. B. Handy-Hotspot).",
                     "vpn.tuwien.ac.at is not reachable right now, or this network blocks VPN. Try again in a few minutes or on another network (e.g. phone hotspot).")
            buttons = [retry, showLog, ok]
        case .passwordRejected:
            title = L("Netzwerkpasswort abgelehnt", "Network password rejected")
            text = L("Der TU-Server hat das Passwort für \(user) nicht akzeptiert.\n\n• Gemeint ist das Netzwerkpasswort, nicht das TISS-Passwort.\n• Ist dein Netzwerk-Account aktiviert und MFA eingerichtet? Siehe Anleitung.",
                     "The TU server did not accept the password for \(user).\n\n• It must be your network password, not your TISS password.\n• Is your network account activated and MFA set up? See the guide.")
            buttons = [(L("Passwort neu eingeben", "Re-enter password"), .reenterPassword),
                       (L("Anleitung öffnen", "Open guide"), .openAccountHelp), cancel]
        case .mfaRejected:
            title = L("MFA-Code abgelehnt", "MFA code rejected")
            text = L("Der Code war falsch oder schon abgelaufen. Warte auf den nächsten Code und versuch's nochmal.",
                     "The code was wrong or already expired. Wait for the next code and try again.")
            buttons = [retry, cancel]
        case .notAuthorized:
            title = L("Kein VPN-Zugang für diesen Account", "No VPN access for this account")
            text = L("Der TU-Server lässt \(user) nicht ins VPN. Meist ist der Netzwerk-Account noch nicht aktiviert oder MFA nicht eingerichtet.",
                     "The TU server does not let \(user) into the VPN. Usually the network account is not activated yet or MFA is not set up.")
            buttons = [(L("Anleitung öffnen", "Open guide"), .openAccountHelp), ok]
        case .sessionLimit:
            title = L("Zu viele offene VPN-Sessions", "Too many open VPN sessions")
            text = L("Pro Account sind höchstens 3 Sessions gleichzeitig erlaubt (auch von Handy oder anderen Geräten). Beende alte Sessions im TU-Portal und verbinde dann neu.",
                     "Each account may have at most 3 sessions at once (including phone or other devices). End old sessions in the TU portal, then connect again.")
            buttons = [(L("Portal öffnen", "Open portal"), .openPortal), cancel]
        case .timeout:
            title = L("Zeitüberschreitung", "Timed out")
            text = L("Die Anmeldung hat zu lange gedauert. Prüf deine Verbindung und versuch's nochmal.",
                     "Signing in took too long. Check your connection and try again.")
            buttons = [retry, ok]
        case .sessionExpired, .unknown:
            title = L("Verbindung fehlgeschlagen", "Connection failed")
            text = details.isEmpty ? L("Unbekannter Fehler.", "Unknown error.") : details
            buttons = [showLog, (L("Hilfe", "Help"), .openHelp), ok]
        }
        if failure != .unknown && failure != .sessionExpired && !details.isEmpty && failure != .passwordRejected
            && failure != .mfaRejected {
            text += "\n\n" + details
        }
        if let logPath { text += "\n\n" + L("Log: ", "Log: ") + logPath }
        if logPath == nil { buttons.removeAll { $0.1 == .openLog } }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        for (label, _) in buttons { alert.addButton(withTitle: label) }
        let response = present(alert)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(index) else { return }
        switch buttons[index].1 {
        case .retry:
            connect(profile)
        case .reenterPassword:
            Keychain.delete(service: Config.passwordKeychainService, account: user)
            connect(profile)
        case .openPortal:
            NSWorkspace.shared.open(Config.sessionsPortalUrl)
        case .openAccountHelp:
            NSWorkspace.shared.open(Config.accountHelpUrl)
        case .openLog:
            if let logPath { openLog(logPath) }
        case .openHelp:
            NSWorkspace.shared.open(Config.projectUrl)
        case .none:
            break
        }
    }

    private func showMissingOpenconnect() {
        let alert = NSAlert()
        alert.messageText = L("openconnect fehlt", "openconnect is missing")
        let command: String
        if isHomebrewInstalled() {
            command = Config.installOpenconnectCommand
            alert.informativeText = L("TU VPN nutzt den freien VPN-Client openconnect. Installier ihn im Terminal:\n\n\(command)",
                                      "TU VPN uses the free VPN client openconnect. Install it in Terminal:\n\n\(command)")
        } else {
            command = "curl -fsSL https://raw.githubusercontent.com/hannokuegler/tu_vpn/main/install.sh | bash"
            alert.informativeText = L("TU VPN nutzt den freien VPN-Client openconnect, der über Homebrew installiert wird. Dieser Befehl im Terminal richtet beides ein:\n\n\(command)",
                                      "TU VPN uses the free VPN client openconnect, installed via Homebrew. This Terminal command sets up both:\n\n\(command)")
        }
        alert.addButton(withTitle: L("Befehl kopieren & Terminal öffnen", "Copy command & open Terminal"))
        alert.addButton(withTitle: L("Abbrechen", "Cancel"))
        if present(alert) == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }

    private func showUnsafeOpenconnect(_ problems: [String]) {
        showError(L("openconnect wird nicht mit Admin-Rechten gestartet", "openconnect will not be started with admin rights"),
                  details: problems.joined(separator: "\n") + "\n\n"
                    + L("Andere Programme könnten es verändern und so Admin-Rechte bekommen. Reparieren im Terminal: brew reinstall openconnect",
                        "Other programs could modify it and gain admin rights. Fix it in Terminal: brew reinstall openconnect"))
    }

    private func confirmForeignVpn(_ pids: [Int32]) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Es läuft schon ein anderes VPN", "Another VPN is already running")
        alert.informativeText = L("openconnect (PID \(pids.map(String.init).joined(separator: ", "))) ist bereits aktiv. Zwei VPNs gleichzeitig vertragen sich oft nicht.",
                                  "openconnect (PID \(pids.map(String.init).joined(separator: ", "))) is already active. Two VPNs at once often conflict.")
        alert.addButton(withTitle: L("Trotzdem verbinden", "Connect anyway"))
        alert.addButton(withTitle: L("Abbrechen", "Cancel"))
        return present(alert) == .alertFirstButtonReturn
    }
}

@main
struct TUvpnApp {
    @MainActor
    static func main() {
        // Aufruf durch uninstall.sh: Autostart-Eintrag sauber abmelden, sonst nichts.
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        // Nur eine Instanz
        if let bundleId = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains(where: { $0.processIdentifier != getpid() }) {
            exit(0)
        }
        let appDelegate = AppDelegate()
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory) // nur Menüleiste, kein Dock-Icon
        application.run()
    }
}
