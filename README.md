# Hopp

Hopp is a keyboard-first window switcher and app launcher for macOS. Press `⌘Tab` to see individual windows in most-recently-used order, type to search by app name or window title (pinyin works for Chinese names), and release the modifier to switch. Press `⌥Space` to search installed apps and launch one.

## Features

| Feature | How it works |
| --- | --- |
| Window switching | Lists individual windows rather than apps, in most recently used (MRU) order |
| Keyboard switcher | `⌘Tab` for all windows and ``⌘` `` for the current app; both are customizable. Shift reverses, arrow keys move, `Esc` cancels, releasing the modifier confirms |
| Search | Hold the modifier and type to filter by app name or window title, including pinyin for Chinese names; matches are highlighted |
| All desktops | Settings → General → Show windows from all desktops groups the switcher by desktop |
| Window activation | Restores minimized or hidden windows when activated |
| App launcher | `⌥Space` (customizable) opens a search box for installed apps, including pinyin and English names of localized apps. `↑`/`↓` select, `↩` launches or brings a running app forward, `Esc` closes |

## Install and permissions

1. Build the app (see below) and move `Hopp.app` to the Applications folder.
2. Hopp lives in the menu bar with no Dock icon. Open “Settings…” from the menu bar icon.
3. Grant Accessibility access in System Settings → Privacy & Security → Accessibility. Hopp needs it to discover and switch windows and to handle global shortcuts.

## Development

Requires macOS 13 or later and Swift 5.9.

```bash
swift test
./scripts/build-app.sh            # release build, signs with an Apple Development identity
SIGNING_MODE=adhoc ./scripts/build-app.sh   # local build without a certificate
./scripts/build-dmg.sh            # package dist/Hopp.app into a DMG
```

Self-checks:

```bash
dist/Hopp.app/Contents/MacOS/Hopp --self-check
dist/Hopp.app/Contents/MacOS/Hopp --ui-self-check
```

## Releasing

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, builds a universal app, packages a DMG and publishes a GitHub release. The tag must match `VERSION`:

```bash
echo 0.2.0 > VERSION
git commit -am "chore(release): prepare v0.2.0"
git tag v0.2.0
git push origin main v0.2.0
```

Signing depends on which repository secrets are set:

| Secrets | Signing |
| --- | --- |
| None | Ad-hoc. Users must right-click → Open the first time, and re-grant Accessibility after every update |
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD` | Self-signed certificate named “Hopp Release Signing”. Accessibility access survives updates |
| The two above plus `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Developer ID certificate, notarized and stapled. Opens without warnings |

`MACOS_CERTIFICATE_P12` is the base64 of an exported `.p12` (`base64 -i cert.p12 | pbcopy`).
