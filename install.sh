#!/bin/bash
# shellcheck disable=SC1111  # typografische Anführungszeichen in Meldungen sind gewollt
# TU VPN — Installer / installer
#
#   curl -fsSL https://raw.githubusercontent.com/hannokuegler/tu_vpn/main/install.sh | bash
#
# Prüft macOS und Homebrew, installiert openconnect, lädt die neueste Release-ZIP von GitHub,
# prüft deren SHA-256 gegen SHA256SUMS, installiert nach /Applications und startet die App.
# Bestimmte Version: TUVPN_VERSION=v0.1.0 bash install.sh
#
# Alles steckt in main(), damit ein abgebrochener Download nie halb ausgeführt wird.

main() {
  set -euo pipefail

  local repo="hannokuegler/tu_vpn"
  local app_name="TU VPN"
  local zip_name="TUvpn-macOS.zip"
  local min_macos_major=13
  local version="${TUVPN_VERSION:-latest}"

  local german=false
  case "$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p')" in *de*) german=true ;; esac
  say() { if $german; then echo "$1"; else echo "$2"; fi; }
  step() { printf '\n\033[1m▸ %s\033[0m\n' "$(say "$1" "$2")"; }
  fail() {
    printf '\n\033[31m✖ %s\033[0m\n' "$(say "$1" "$2")" >&2
    exit 1
  }
  ask_yes() { # liest von der Tastatur, auch wenn das Skript per Pipe kommt
    local answer
    [ -r /dev/tty ] || return 1
    printf '%s ' "$(say "$1 [j/N]" "$2 [y/N]")"
    read -r answer </dev/tty || return 1
    case "$answer" in [jJyY]*) return 0 ;; *) return 1 ;; esac
  }

  # ── macOS ────────────────────────────────────────────────────────────────
  [ "$(uname -s)" = "Darwin" ] || fail "TU VPN läuft nur auf macOS." "TU VPN only runs on macOS."
  local macos_version macos_major
  macos_version=$(sw_vers -productVersion)
  macos_major=${macos_version%%.*}
  if [ "$macos_major" -lt "$min_macos_major" ]; then
    fail "macOS $macos_version ist zu alt – TU VPN braucht macOS $min_macos_major (Ventura) oder neuer." \
      "macOS $macos_version is too old – TU VPN needs macOS $min_macos_major (Ventura) or newer."
  fi
  [ "$(id -u)" != 0 ] || fail "Bitte ohne sudo ausführen." "Please run without sudo."
  say "TU VPN – Installation (inoffizielles Studi-Projekt, nicht von der TU Wien)" \
    "TU VPN – installation (unofficial student project, not affiliated with TU Wien)"

  # ── Homebrew ─────────────────────────────────────────────────────────────
  step "Homebrew prüfen" "Checking Homebrew"
  local brew=""
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then brew="$candidate"; break; fi
  done
  if [ -z "$brew" ]; then
    say "Homebrew fehlt. Homebrew ist der übliche Paketmanager für macOS (https://brew.sh);" \
      "Homebrew is missing. Homebrew is the common package manager for macOS (https://brew.sh);"
    say "TU VPN braucht ihn für den freien VPN-Client openconnect." \
      "TU VPN needs it for the free VPN client openconnect."
    if ask_yes "Homebrew jetzt mit dem offiziellen Installer einrichten?" "Install Homebrew now with the official installer?"; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
      for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then brew="$candidate"; break; fi
      done
      [ -n "$brew" ] || fail "Homebrew-Installation nicht gefunden." "Homebrew installation not found."
    else
      fail "Bitte zuerst Homebrew installieren (https://brew.sh) und dann diesen Befehl nochmal ausführen." \
        "Please install Homebrew first (https://brew.sh), then run this command again."
    fi
  fi
  echo "  $brew"

  # ── openconnect ──────────────────────────────────────────────────────────
  step "openconnect prüfen" "Checking openconnect"
  if "$brew" list --formula openconnect >/dev/null 2>&1; then
    echo "  $("$brew" --prefix)/bin/openconnect ✓"
  else
    say "  installiere openconnect …" "  installing openconnect …"
    "$brew" install openconnect </dev/null || fail "brew install openconnect ist fehlgeschlagen." "brew install openconnect failed."
  fi

  # ── Release laden und prüfen ─────────────────────────────────────────────
  step "App herunterladen" "Downloading the app"
  local base_url
  if [ "$version" = "latest" ]; then
    base_url="https://github.com/$repo/releases/latest/download"
  else
    base_url="https://github.com/$repo/releases/download/$version"
  fi
  # global, damit der EXIT-Trap ihn nach main noch kennt
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tuvpn-install.XXXXXX")
  trap 'rm -rf "${work_dir:-}"' EXIT
  curl -fsSL --proto '=https' --tlsv1.2 -o "$work_dir/$zip_name" "$base_url/$zip_name" \
    || fail "Download fehlgeschlagen: $base_url/$zip_name" "Download failed: $base_url/$zip_name"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$work_dir/SHA256SUMS" "$base_url/SHA256SUMS" \
    || fail "Download fehlgeschlagen: $base_url/SHA256SUMS" "Download failed: $base_url/SHA256SUMS"

  step "Prüfsumme (SHA-256) prüfen" "Verifying checksum (SHA-256)"
  local expected actual
  expected=$(awk -v name="$zip_name" '$2 == name || $2 == "*" name { print $1 }' "$work_dir/SHA256SUMS")
  actual=$(shasum -a 256 "$work_dir/$zip_name" | awk '{ print $1 }')
  [ -n "$expected" ] || fail "SHA256SUMS enthält keinen Eintrag für $zip_name." "SHA256SUMS has no entry for $zip_name."
  [ "$expected" = "$actual" ] || fail "Prüfsumme stimmt nicht – Download beschädigt oder manipuliert. Abbruch." \
    "Checksum mismatch – download damaged or tampered with. Aborting."
  echo "  $actual ✓"

  ditto -x -k "$work_dir/$zip_name" "$work_dir/unpacked"
  local new_app="$work_dir/unpacked/$app_name.app"
  [ -d "$new_app" ] || fail "Die ZIP enthält keine App." "The ZIP contains no app."
  codesign --verify --strict "$new_app" 2>/dev/null \
    || fail "Die Signatur der App ist ungültig. Abbruch." "The app's signature is invalid. Aborting."

  # ── Installieren ─────────────────────────────────────────────────────────
  step "Installieren" "Installing"
  local target_dir="/Applications"
  if [ ! -w "$target_dir" ]; then
    target_dir="$HOME/Applications"
    mkdir -p "$target_dir"
    say "  /Applications ist nicht beschreibbar – installiere nach $target_dir" \
      "  /Applications is not writable – installing to $target_dir"
  fi
  pkill -x TUvpn 2>/dev/null || true # nur die App; eine laufende VPN-Verbindung bleibt bestehen
  sleep 1
  rm -rf "${target_dir:?}/$app_name.app"
  ditto "$new_app" "$target_dir/$app_name.app"
  echo "  $target_dir/$app_name.app ✓"

  open "$target_dir/$app_name.app"
  printf '\n\033[32m✔ %s\033[0m\n' "$(say "Fertig! TU VPN sitzt jetzt oben rechts in der Menüleiste („TU“)." \
    "Done! TU VPN now lives in the menu bar at the top right (“TU”).")"
  say "  Beim ersten Start fragt die App deinen TU-Login (e + Matrikelnummer) ab." \
    "  On first launch the app asks for your TU login (e + matriculation number)."
}

main "$@"
