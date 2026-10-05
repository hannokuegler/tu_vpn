#!/bin/bash
# Tests für Helper/tuvpn-helper und Helper/tuvpn-setup.sh (Prüfregeln, sudoers-Regel).
# Läuft ohne root: ./build.sh test
set -u
cd "$(dirname "$0")/.."

failures=0
checks=0
expect() { # expect <0|1> <beschreibung> <befehl …>
  local expected="$1" description="$2"
  shift 2
  checks=$((checks + 1))
  if "$@"; then actual=0; else actual=1; fi
  if [ "$actual" != "$expected" ]; then
    failures=$((failures + 1))
    echo "FAIL: $description (erwartet $expected, bekommen $actual)"
  fi
}

summary() { echo "$((checks - failures))/$checks shell checks ok ($1)"; [ "$failures" -eq 0 ]; }

# Beide Skripte definieren dieselben readonly-Konstanten → je eigene Subshell.
(
# shellcheck source=../Helper/tuvpn-helper
source Helper/tuvpn-helper
set +e

fingerprint="pin-sha256:$(printf 'A%.0s' {1..43})="
expect 0 "Profil 1" valid_profile 1_TU_getunnelt
expect 0 "Profil 2" valid_profile 2_Alles_getunnelt
expect 1 "fremdes Profil" valid_profile 3_x
expect 1 "Profil mit Injection" valid_profile "1_TU_getunnelt;id"
expect 0 "Standard-URL" valid_connect_url "https://vpn.tuwien.ac.at/"
expect 0 "URL mit Port/Pfad" valid_connect_url "https://vpn.tuwien.ac.at:443/a?b=c&d=e"
expect 0 "URL ohne Pfad" valid_connect_url "https://vpn.tuwien.ac.at"
expect 1 "http" valid_connect_url "http://vpn.tuwien.ac.at/"
expect 1 "fremder Host" valid_connect_url "https://vpn.tuwien.ac.at.evil.example/"
expect 1 "anderer Port" valid_connect_url "https://vpn.tuwien.ac.at:8443/"
expect 1 "Quote" valid_connect_url "https://vpn.tuwien.ac.at/'x"
expect 1 "Command Substitution" valid_connect_url 'https://vpn.tuwien.ac.at/$(id)'
expect 1 "Leerzeichen" valid_connect_url "https://vpn.tuwien.ac.at/ x"
expect 1 "zu lang" valid_connect_url "https://vpn.tuwien.ac.at/$(printf 'a%.0s' {1..600})"
expect 0 "Fingerprint" valid_fingerprint "$fingerprint"
expect 1 "Fingerprint zu kurz" valid_fingerprint "pin-sha256:AAAA="
expect 1 "sha1-Fingerprint" valid_fingerprint "sha1:0123456789abcdef0123456789abcdef01234567"
expect 1 "Fingerprint mit Zeilenumbruch" valid_fingerprint "$fingerprint"$'\n'"x"
expect 0 "Cookie" valid_cookie "webvpn=ABC@123@456@DEF"
expect 1 "leeres Cookie" valid_cookie ""
expect 1 "Cookie mit Leerzeichen" valid_cookie "a b"
expect 1 "Cookie mit Quote" valid_cookie "a'b"
expect 1 "Cookie mit Backtick" valid_cookie 'a`id`'
expect 1 "Cookie mit Backslash" valid_cookie 'a\b'
expect 1 "Cookie zu lang" valid_cookie "$(printf 'a%.0s' {1..8200})"
expect 1 "Helper verweigert ohne root" bash Helper/tuvpn-helper connect 1_TU_getunnelt </dev/null 2>/dev/null
summary tuvpn-helper
) || failures=$((failures + 1))

(
# sudoers-Regel aus dem Setup
# shellcheck source=../Helper/tuvpn-setup.sh
source Helper/tuvpn-setup.sh
set +e
rule_file=$(mktemp)
sudoers_rule "$(id -un)" >"$rule_file"
expect 0 "sudoers-Regel ist gültig (visudo -cf)" visudo -qcf "$rule_file"
expect 0 "Regel nennt nur den Helper" grep -q "NOPASSWD: /Library/TUvpn/tuvpn-helper connect 1_TU_getunnelt, /Library/TUvpn/tuvpn-helper connect 2_Alles_getunnelt, /Library/TUvpn/tuvpn-helper disconnect hup, /Library/TUvpn/tuvpn-helper disconnect int$" "$rule_file"
expect 1 "keine Wildcards in der Regel" grep -q '\*' "$rule_file"
rm -f "$rule_file"
expect 0 "eigener User gültig" valid_username "$(id -un)"
expect 1 "User mit Leerzeichen" valid_username "a b"
expect 1 "User mit Komma" valid_username "a,ALL"
expect 1 "unbekannter User" valid_username "gibtsnicht_tuvpn"

summary tuvpn-setup.sh
) || failures=$((failures + 1))

[ "$failures" -eq 0 ]
