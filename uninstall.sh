#!/bin/bash
# shellcheck disable=SC1111  # typografische Anführungszeichen in Meldungen sind gewollt
# TU VPN — Deinstallation / uninstall
#
#   curl -fsSL https://raw.githubusercontent.com/hannokuegler/tu_vpn/main/uninstall.sh | bash
#
# Entfernt die App, den Autostart-Eintrag, Schlüsselbund-Einträge, Einstellungen, Logs und – falls
# eingerichtet – den Modus "Ohne Mac-Passwort" (/Library/TUvpn + /etc/sudoers.d/tuvpn, fragt nach sudo).
# openconnect/Homebrew bleiben installiert (brew uninstall openconnect, falls gewünscht).

main() {
  set -uo pipefail
  local german=false
  case "$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p')" in *de*) german=true ;; esac
  say() { if $german; then echo "$1"; else echo "$2"; fi; }

  if pgrep -x openconnect >/dev/null && [ -f /var/run/tuvpn.pid ]; then
    say "Hinweis: Eine TU-VPN-Verbindung läuft noch. Am besten vorher im Menü „Abmelden“ wählen." \
      "Note: a TU VPN connection is still running. Ideally choose “Log out” in the menu first."
  fi

  local app
  for app in "/Applications/TU VPN.app" "$HOME/Applications/TU VPN.app"; do
    if [ -d "$app" ]; then
      "$app/Contents/MacOS/TUvpn" --unregister-login-item 2>/dev/null || true
      pkill -x TUvpn 2>/dev/null || true
      rm -rf "$app" && say "✓ $app entfernt" "✓ removed $app"
    fi
  done

  local service
  for service in TUvpn TUvpn-session; do
    while security delete-generic-password -s "$service" >/dev/null 2>&1; do :; done
  done
  say "✓ Schlüsselbund-Einträge entfernt" "✓ removed Keychain items"

  local domain
  for domain in io.github.hannokuegler.tuvpn io.github.tuvpn-mac; do
    defaults delete "$domain" >/dev/null 2>&1 || true
  done
  rm -f "$HOME/Library/Logs/TUvpn-auth.log"
  say "✓ Einstellungen und Anmelde-Log entfernt" "✓ removed settings and login log"

  local root_paths=()
  local path
  for path in /etc/sudoers.d/tuvpn /Library/TUvpn /var/log/tuvpn.log /var/run/tuvpn.pid; do
    if [ -e "$path" ]; then root_paths+=("$path"); fi
  done
  if [ "${#root_paths[@]}" -gt 0 ]; then
    say "Admin-Rechte nötig für: ${root_paths[*]}" "Admin rights needed for: ${root_paths[*]}"
    # shellcheck disable=SC2024  # /dev/tty ist für die Passwortabfrage von sudo gedacht
    if sudo /bin/rm -rf "${root_paths[@]}" </dev/tty; then
      say "✓ entfernt" "✓ removed"
    else
      say "✖ konnte nicht entfernt werden – bitte manuell: sudo rm -rf ${root_paths[*]}" \
        "✖ could not remove – please run: sudo rm -rf ${root_paths[*]}"
    fi
  fi

  say "Fertig. openconnect bleibt installiert (entfernen: brew uninstall openconnect)." \
    "Done. openconnect stays installed (remove: brew uninstall openconnect)."
}

main "$@"
