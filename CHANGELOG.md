# Changelog

Alle nennenswerten Änderungen · All notable changes. Format: [Keep a Changelog](https://keepachangelog.com/), Versionen nach [SemVer](https://semver.org/).

## [0.1.0] – 2026-10-05

Erste öffentliche Version · First public release.

### Added
- Menüleisten-App „TU“ fürs TUvpn der TU Wien auf Basis von openconnect (AnyConnect), Universal (Apple Silicon + Intel), macOS 13+
- Profile *Nur TU* (`1_TU_getunnelt`) und *Alles getunnelt* (`2_Alles_getunnelt`); Statusanzeige TU / TU+ / TU…
- MFA nur einmal pro TU-Session: Session-Cookie im Schlüsselbund, *Trennen* (Session bleibt) vs. *Abmelden* (Session endet)
- Abgelaufene Session → still neu einloggen
- Übersteht Ruhezustand/WLAN-Wechsel: openconnect läuft mit `--reconnect-timeout 86400`
- Optionaler Modus **Ohne Mac-Passwort**: root-eigene, sandboxed openconnect-Kopie in `/Library/TUvpn`, Helper mit fester Schnittstelle, enge sudo-Regel
- Erststart-Dialog (Login + Autostart), Deutsch/Englisch nach Systemsprache
- Fehlermeldungen mit nächstem Schritt: kein Internet, Server nicht erreichbar, Passwort vs. MFA falsch, keine VPN-Berechtigung, Session-Limit (Portal-Knopf), openconnect fehlt (Befehl kopieren + Terminal), Tunnel-Abbruch (Mitteilung)
- `install.sh` (Einzeiler mit SHA-256-Prüfung) und `uninstall.sh`
- Release-Builds in GitHub Actions mit `SHA256SUMS` und Build-Provenance-Attestation; Actions per SHA gepinnt, Dependabot
- Tests für Validierung, Parsing, root-Befehle und Shell-Helper (`./build.sh test`, nur Command Line Tools)

### Security
- Tunnel-Log und PID-Datei an root-eigenen Orten (`/var/log/tuvpn.log`, `/var/run/tuvpn.pid`) statt `/tmp`
- Trennen signalisiert nur den eigenen openconnect-Prozess statt `pkill openconnect`
- Alle Eingaben für root-Befehle werden validiert und gequotet; Cookie-Datei exklusiv mit `0600`
- Details: [SECURITY.md](SECURITY.md)

[0.1.0]: https://github.com/hannokuegler/tu_vpn/releases/tag/v0.1.0
