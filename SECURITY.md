# Security

> Kurz auf Deutsch: Sicherheitslücken bitte **nicht** als öffentliches Issue melden, sondern über
> [„Report a vulnerability“](https://github.com/hannokuegler/tu_vpn/security/advisories/new) (privat).
> Unten steht, wovor TU VPN schützt, wie – und wo die Grenzen liegen.

## Reporting a vulnerability

Please report security issues **privately** via GitHub:
[Security → Report a vulnerability](https://github.com/hannokuegler/tu_vpn/security/advisories/new).
Do not open a public issue. Expect a first answer within about a week (this is a student side
project). Supported version: the latest release.

## What TU VPN does with privileges

TU VPN is a menu bar app that runs as **your user**. Building the VPN tunnel needs **root**, because
openconnect creates a network interface and changes routes and DNS. There are two ways root is used:

| Mode | How root is obtained | What runs as root |
|---|---|---|
| **Admin dialog** (default) | macOS asks for an admin password on every connect/disconnect (`do shell script … with administrator privileges`) | Homebrew's `openconnect`, started with a command built and validated by the app |
| **Without Mac password** (opt-in) | one admin prompt at setup; afterwards `sudo -n` with a NOPASSWD rule restricted to one helper and four exact argument lists | the root-owned helper `/Library/TUvpn/tuvpn-helper` and a root-owned copy of openconnect, inside a sandbox |

## Assets

- TU network password (Keychain, service `TUvpn`)
- TU session cookie, connect URL and server fingerprint (Keychain, service `TUvpn-session`) — valid for ~5 days
- the 6-digit MFA code (only in memory, sent once)
- root on your Mac

## Threat model

| # | Attacker | In scope? |
|---|---|---|
| T1 | Someone on the network (café Wi-Fi, MITM) | yes |
| T2 | Another local user account on the same Mac | yes |
| T3 | Malicious data in TU VPN's own Keychain items or files (e.g. planted by other software) | yes |
| T4 | Malware already running **as your user** | partly — see limits below |
| T5 | Tampered downloads / compromised build | yes, as far as checksums and provenance allow |
| T6 | A compromised TU VPN server | no — the server is trusted by design, like with the official client |

## Measures

**Secrets**
- Password and session cookie are stored only in the macOS Keychain.
- Secrets are passed to openconnect **only via stdin**, never as command-line arguments (those are visible to every user via `ps`). In passwordless mode the cookie is piped with the shell builtin `printf`, so it never appears in any process list.
- In admin-dialog mode the root process reads the cookie from a file that is created **exclusively** (`O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0600`) inside a fresh `0700` directory in your per-user temp folder, and deleted right after the root command returns (`defer`).
- Logs never contain password, MFA code or cookie. The login log `~/Library/Logs/TUvpn-auth.log` is `0600`.

**Everything that reaches root is validated and quoted** (`Sources/Core/Session.swift`, `Sources/Core/RootCommand.swift`, `Helper/tuvpn-helper`)
- connect URL: must be `https://vpn.tuwien.ac.at[:443]/…`, no user info, only a conservative character set
- fingerprint: exactly `pin-sha256:` + 44 base64 characters (32 bytes)
- cookie: printable ASCII without spaces, quotes, backslash or backtick, max. 8 KiB
- profile: only `1_TU_getunnelt` or `2_Alles_getunnelt`
- openconnect path: only from a fixed list (`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/sbin`)
- every variable part is single-quoted for the shell, then escaped for AppleScript; unit tests check the exact commands, including injection attempts (`'`, `$(…)`, `..`)
- Data read back from the Keychain goes through the same validation — a planted entry with a foreign URL is discarded (T3).

**No symlink or PID games (T2)**
- The tunnel log is `/var/log/tuvpn.log` and the PID file `/var/run/tuvpn.pid` — directories where only root can create files. (Earlier development versions wrote `/tmp/tuvpn.log` as root, which allowed a symlink attack by any local user.)
- Disconnecting signals **only** the PID from that root-owned PID file, and only after re-checking as root that the process really is `openconnect`. TU VPN no longer uses `pkill openconnect`, so other VPNs are never touched.

**TLS (T1)**
- Login: openconnect verifies the server certificate against the system's trusted CAs.
- Admin-dialog tunnel: pinned to the certificate fingerprint obtained during that verified login (`--servercert pin-sha256:…`).
- Passwordless tunnel: the helper ignores the caller's fingerprint and verifies the certificate **and hostname** against macOS's root-owned CA bundle `/etc/ssl/cert.pem`, so a caller can't sneak in a pin of its own.

**Binary checks**
- Before starting Homebrew's openconnect as root, the app refuses binaries (and their directories) that are world-writable or owned by another non-root user.

**Supply chain (T5)**
- Release builds are made by GitHub Actions on a GitHub-hosted macOS runner from the tagged commit, never on a developer machine.
- Each release has `SHA256SUMS` and a signed [build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations) (Sigstore). Verify with `gh attestation verify TUvpn-macOS.zip --repo hannokuegler/tu_vpn`.
- `install.sh` downloads over HTTPS only (`--proto =https --tlsv1.2`), compares the SHA-256 against `SHA256SUMS`, checks the code signature, and aborts on any mismatch. The whole script is wrapped in a function, so a truncated download never runs half.
- GitHub Actions are pinned to full commit SHAs, workflows have minimal `permissions` (read-only by default; only the release job may write releases and attestations), and Dependabot keeps the pins up to date.

## Passwordless mode in detail

Goal: after setup, code running as your user can do **nothing more with root than connect or disconnect the TU VPN**.

- **Root-owned copy.** Setup copies openconnect plus all non-system libraries it links (found recursively with `otool -L`) into `/Library/TUvpn/`, rewrites the library references to `@loader_path` with `install_name_tool`, re-signs ad hoc, and sets owner `root:wheel` with no group/other write permission. The vpnc-script is copied too. Nothing in `/Library/TUvpn` is writable by your user.
- **Sandbox.** We found that openconnect's TLS stack loads plugins at runtime from the Homebrew prefix (e.g. `p11-kit-trust.dylib`, via p11-kit's compiled-in configuration) — even from the copy. Since that prefix belongs to your user, that would be a root escalation. The helper therefore starts openconnect with `sandbox-exec` and a profile that denies reading or mapping anything under `/opt/homebrew`, `/usr/local`, `/opt/local` and `/Users`. The setup's self-test (also run in CI) starts the copy inside that sandbox; a manual check confirmed that a TLS handshake with `vpn.tuwien.ac.at` inside the sandbox loads nothing from those paths and still verifies the certificate.
- **Fixed helper interface.** `tuvpn-helper connect <profile>` (cookie, URL, fingerprint on stdin, strictly validated) and `tuvpn-helper disconnect hup|int` (PID only from the root-owned PID file, process name re-checked). No other commands, no paths or options from outside, `PATH`/`IFS`/locale reset, `bash -p`.
- **Narrow sudo rule.** `/etc/sudoers.d/tuvpn` (mode `0440`, checked with `visudo -cf` before installing and `visudo -c` afterwards) contains a single line for the user who set it up, listing exactly these four commands — no wildcards:
  ```
  <user> ALL=(root) NOPASSWD: /Library/TUvpn/tuvpn-helper connect 1_TU_getunnelt, /Library/TUvpn/tuvpn-helper connect 2_Alles_getunnelt, /Library/TUvpn/tuvpn-helper disconnect hup, /Library/TUvpn/tuvpn-helper disconnect int
  ```
- **Updates.** The copy does not change when Homebrew updates openconnect. The app notices (`/Library/TUvpn/VERSION` vs. the current Homebrew path) and offers to set it up again.
- **Removal.** Menu item, or `uninstall.sh`; both delete `/etc/sudoers.d/tuvpn` and `/Library/TUvpn`.

**What remains possible for code running as you (T4) in this mode:** connecting or disconnecting the TU VPN at will, and choosing which (validly formatted) session cookie is used — i.e. it could log you into the VPN with a different TU account's session it somehow obtained. It cannot pick another server, another certificate, other options, or run other programs as root.

## Known limits (please read)

1. **Admin-dialog mode runs a user-writable binary as root.** Homebrew installs openconnect into a prefix owned by your user. Any program running as you could replace it, and the next time you approve the admin dialog, that program runs as root. This is the same for every Homebrew tool you run with `sudo`. TU VPN checks for obviously unsafe permissions, but cannot rule this out. If that matters to you, use the passwordless mode (it runs a root-owned copy) or a root-owned openconnect (e.g. MacPorts in `/opt/local`).
2. **The app itself is user-writable.** Like most apps you drag into `/Applications`, TU VPN's bundle belongs to your user. Malware running as you could modify it and then ask for admin rights in its name. The admin dialog always says which app is asking — only approve it when you just clicked *Connect*/*Disconnect*/*Set up*.
3. **Setup is a trust moment.** Setting up the passwordless mode runs a script from the app bundle as root and copies Homebrew's openconnect at that moment. If your user account was already compromised before setup, the copy may be too.
4. **Not notarized.** The app is signed ad hoc, not with an Apple Developer ID, so Gatekeeper can't vouch for it. Integrity comes from the checksum and the CI provenance instead (see above).
5. **Why not passwordless by default?** A NOPASSWD rule pointing at Homebrew's user-writable openconnect would be a silent root escalation for every program running as you. That's why the passwordless mode is opt-in and always uses the root-owned, sandboxed copy.

## Roadmap

- Developer ID signing + notarization (needs a paid Apple Developer account)
- A privileged helper via `SMAppService.daemon` with XPC and code-signing requirements instead of sudo, once the app is signed with a stable Team ID
