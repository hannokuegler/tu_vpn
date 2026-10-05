#!/bin/bash -p
# tuvpn-setup.sh — richtet den optionalen Modus "Ohne Mac-Passwort" von TU VPN ein oder entfernt ihn.
#
#   tuvpn-setup.sh build <zielordner>   baut die eigenständige openconnect-Kopie in einen Ordner
#                                       (ohne root — zum Testen)
#   tuvpn-setup.sh install <user>       als root: Kopie nach /Library/TUvpn (root:wheel, für User nicht
#                                       schreibbar) + /etc/sudoers.d/tuvpn (NOPASSWD nur für den Helper)
#   tuvpn-setup.sh uninstall            als root: entfernt /Library/TUvpn und /etc/sudoers.d/tuvpn
#
# Warum eine Kopie? Das Homebrew-openconnect gehört dem User. Eine passwortlose sudo-Regel darauf
# wäre eine stille Root-Eskalation für jedes Programm des Users. Die Kopie samt ihren dylibs gehört
# root; der User kann über sudo nur noch "TU-VPN verbinden/trennen" auslösen.

set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
umask 022

readonly INSTALL_DIR=/Library/TUvpn
readonly SUDOERS_FILE=/etc/sudoers.d/tuvpn
readonly HELPER_VERSION=1
readonly OPENCONNECT_CANDIDATES=(/opt/homebrew/bin/openconnect /usr/local/bin/openconnect /opt/local/sbin/openconnect)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
CLEANUP_PATHS=()
trap 'rm -rf ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}' EXIT

die() {
  echo "tuvpn-setup: $*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" = 0 ] || die "must run as root"
}

find_openconnect() {
  local candidate
  for candidate in "${OPENCONNECT_CANDIDATES[@]}"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  die "openconnect not found (brew install openconnect)"
}

# Abhängigkeiten einer Mach-O-Datei, ohne die Zeile mit dem eigenen Namen.
dependencies_of() {
  otool -L "$1" | tail -n +2 | awk '{print $1}'
}

# Kopiert openconnect + alle nicht-systemeigenen dylibs nach <ziel>/bin und <ziel>/lib,
# biegt die Verweise auf @loader_path um und signiert alles ad-hoc neu.
build_bundle() {
  local target="$1" openconnect real_binary vpnc_script queue_file origin_file
  if ! command -v otool >/dev/null || ! command -v install_name_tool >/dev/null; then
    die "otool/install_name_tool missing — install the Command Line Tools: xcode-select --install"
  fi
  otool -h /bin/ls >/dev/null 2>&1 || die "otool does not work — install the Command Line Tools: xcode-select --install"

  # Die Sandbox des Helpers sperrt diese Pfade — eine Kopie darin könnte nicht starten.
  case "$target" in
    /Users/* | /opt/homebrew/* | /usr/local/* | /opt/local/*)
      die "target must not be inside /Users, /opt/homebrew, /usr/local or /opt/local (use e.g. /private/tmp/…)" ;;
  esac
  case "$target" in
    /*) ;;
    *) die "target must be an absolute path" ;;
  esac
  openconnect=$(find_openconnect)
  real_binary=$(realpath "$openconnect")
  local help_text
  help_text=$("$openconnect" --help 2>&1 || true) # --help endet mit Exit 1
  vpnc_script=$(sed -n 's/.*[Dd]efault: "\(.*vpnc-script\)".*/\1/p' <<<"$help_text")
  vpnc_script=${vpnc_script%%$'\n'*}
  if [ -z "$vpnc_script" ] || [ ! -f "$vpnc_script" ]; then
    die "vpnc-script not found (brew reinstall openconnect)"
  fi

  mkdir -p "$target/bin" "$target/lib"
  cp "$real_binary" "$target/bin/openconnect"
  chmod 755 "$target/bin/openconnect"

  # Warteschlange: "<kopierte Datei>\t<Ordner des Originals>"
  queue_file=$(mktemp "${TMPDIR:-/tmp}/tuvpn-queue.XXXXXX")
  origin_file=$(mktemp "${TMPDIR:-/tmp}/tuvpn-origin.XXXXXX")
  CLEANUP_PATHS+=("$queue_file" "$origin_file")
  printf '%s\t%s\n' "$target/bin/openconnect" "$(dirname "$real_binary")" >"$queue_file"

  local line_number=1 entry copied original_dir dependency resolved name reference
  while entry=$(sed -n "${line_number}p" "$queue_file") && [ -n "$entry" ]; do
    copied=${entry%%$'\t'*}
    original_dir=${entry#*$'\t'}
    while IFS= read -r dependency; do
      case "$dependency" in
        /usr/lib/* | /System/*) continue ;;
        @loader_path/*) resolved="$original_dir/${dependency#@loader_path/}" ;;
        @rpath/* | @executable_path/*) die "unsupported dependency $dependency in $copied" ;;
        /*) resolved="$dependency" ;;
        *) die "unexpected dependency $dependency in $copied" ;;
      esac
      name=$(basename "$dependency")
      [ "$name" = "$(basename "$copied")" ] && [ "$copied" != "$target/bin/openconnect" ] && continue
      resolved=$(realpath "$resolved")
      if [ ! -e "$target/lib/$name" ]; then
        cp "$resolved" "$target/lib/$name"
        chmod 644 "$target/lib/$name"
        printf '%s\t%s\n' "$name" "$resolved" >>"$origin_file"
        printf '%s\t%s\n' "$target/lib/$name" "$(dirname "$resolved")" >>"$queue_file"
      elif ! grep -qxF "$(printf '%s\t%s' "$name" "$resolved")" "$origin_file"; then
        die "two different libraries named $name"
      fi
      if [ "$copied" = "$target/bin/openconnect" ]; then
        reference="@loader_path/../lib/$name"
      else
        reference="@loader_path/$name"
      fi
      install_name_tool -change "$dependency" "$reference" "$copied" 2>/dev/null \
        || die "install_name_tool failed for $copied"
    done < <(dependencies_of "$copied")
    if [ "$copied" != "$target/bin/openconnect" ]; then
      install_name_tool -id "@loader_path/$(basename "$copied")" "$copied" 2>/dev/null \
        || die "install_name_tool failed for $copied"
    fi
    line_number=$((line_number + 1))
  done

  local file
  for file in "$target"/lib/*.dylib "$target/bin/openconnect"; do
    codesign --force --sign - "$file" 2>/dev/null || die "codesign failed for $file"
  done

  cp "$vpnc_script" "$target/vpnc-script"
  chmod 755 "$target/vpnc-script"
  cp "$SCRIPT_DIR/tuvpn-helper" "$target/tuvpn-helper"
  chmod 755 "$target/tuvpn-helper"
  {
    echo "helper=$HELPER_VERSION"
    echo "source=$real_binary"
    local version_text
    version_text=$("$target/bin/openconnect" --version 2>&1 || true)
    echo "openconnect=${version_text%%$'\n'*}"
  } >"$target/VERSION"
  chmod 644 "$target/VERSION"

  # Selbsttest: keine Verweise mehr ins Homebrew-Verzeichnis, Kopie startet.
  local dependencies
  for file in "$target"/lib/*.dylib "$target/bin/openconnect"; do
    dependencies=$(dependencies_of "$file")
    if grep -vE '^(/usr/lib/|/System/|@loader_path/)' <<<"$dependencies" | grep -q .; then
      die "$file still references libraries outside the bundle"
    fi
  done
  local sandbox_profile
  sandbox_profile=$(sed -n "s/^readonly SANDBOX_PROFILE='\(.*\)'$/\1/p" "$SCRIPT_DIR/tuvpn-helper")
  [ -n "$sandbox_profile" ] || die "sandbox profile not found in tuvpn-helper"
  /usr/bin/sandbox-exec -p "$sandbox_profile" "$target/bin/openconnect" --version >/dev/null 2>&1 \
    || die "copied openconnect does not start inside the sandbox"
}

valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] && id -u "$1" >/dev/null 2>&1
}

sudoers_rule() {
  local user="$1" helper="$INSTALL_DIR/tuvpn-helper"
  echo "# TU VPN (https://github.com/hannokuegler/tu_vpn): connect/disconnect without the Mac password."
  echo "# Only for user $user and only these exact commands. Remove via the app menu or uninstall.sh."
  echo "$user ALL=(root) NOPASSWD: $helper connect 1_TU_getunnelt, $helper connect 2_Alles_getunnelt, $helper disconnect hup, $helper disconnect int"
}

install_mode() {
  local user="$1" staging sudoers_temp
  require_root
  valid_username "$user" || die "invalid user name: $user"
  grep -qE '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers\.d' /etc/sudoers \
    || die "/etc/sudoers does not include /etc/sudoers.d"

  staging=$(mktemp -d /Library/.TUvpn-staging.XXXXXX)
  sudoers_temp=$(mktemp /tmp/tuvpn-sudoers.XXXXXX)
  CLEANUP_PATHS+=("$staging" "$sudoers_temp")

  build_bundle "$staging"
  chown -R root:wheel "$staging"
  chmod -R go-w "$staging"
  chmod 755 "$staging"

  sudoers_rule "$user" >"$sudoers_temp"
  visudo -cf "$sudoers_temp" >/dev/null || die "generated sudoers rule is invalid"

  rm -rf "$INSTALL_DIR"
  mv "$staging" "$INSTALL_DIR"
  install -m 0440 -o root -g wheel "$sudoers_temp" "$SUDOERS_FILE"
  if ! visudo -c >/dev/null; then
    rm -f "$SUDOERS_FILE"
    die "sudo configuration check failed — rule removed again"
  fi
  echo "TU VPN: passwordless mode set up for $user"
}

uninstall_mode() {
  require_root
  rm -f "$SUDOERS_FILE"
  rm -rf "$INSTALL_DIR"
  echo "TU VPN: passwordless mode removed"
}

main() {
  case "${1:-}" in
    build) [ "$#" -eq 2 ] || die "usage: $0 build <target-dir>"; build_bundle "$2" ;;
    install) [ "$#" -eq 2 ] || die "usage: $0 install <user>"; install_mode "$2" ;;
    uninstall) uninstall_mode ;;
    *) die "usage: $0 build <target-dir> | install <user> | uninstall" ;;
  esac
}

# Beim Einbinden in die Tests (source) nichts ausführen.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
