# Contributing

Danke fürs Mitmachen! · Thanks for helping! Issues and PRs in German or English are both fine.

## Bugs & ideas

Use the [issue forms](https://github.com/hannokuegler/tu_vpn/issues/new/choose). For bugs, the macOS version, TU VPN version and the relevant log lines help most — **remove anything personal** (your e-number is fine to redact). Security issues: privately, see [SECURITY.md](SECURITY.md).

## Code

Only the Xcode Command Line Tools are needed:

```bash
./build.sh test       # Swift logic tests + shell helper tests
./build.sh            # build build/TU VPN.app (universal)
./build.sh --install  # build, copy to /Applications, launch
```

| Path | Content |
|---|---|
| `Sources/Core/` | pure logic, no AppKit: validation, parsing, error classification, root commands — **tested** |
| `Sources/App/` | AppKit menu bar app and system glue (Keychain, processes, admin rights) |
| `Helper/` | root helper and setup script for the passwordless mode |
| `Tests/` | `main.swift` (no XCTest needed) and `helper_tests.sh` |
| `install.sh`, `uninstall.sh` | one-line installer / uninstaller |
| `scripts/` | generators for the app icon and the README illustration |

Guidelines:
- New logic goes into `Sources/Core` with a test in `Tests/main.swift` (test first if you can).
- Anything that ends up in a root command or the helper must be validated **and** quoted — add a test with an injection attempt.
- User-facing text always in both languages: `L("Deutsch", "English")`.
- The menu bar shows text only (`TU`, `TU+`, `TU…`) — no icon, by design.
- No TU logos or branding; this stays an unofficial project.
- Keep it small: one app, no external Swift dependencies.

## Releases

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`, add a `CHANGELOG.md` entry and `docs/release-notes/vX.Y.Z.md`.
2. Tag `vX.Y.Z` and push the tag — GitHub Actions tests, builds, attests and publishes the release.
