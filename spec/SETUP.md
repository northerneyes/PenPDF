# PenPDF — What the owner needs to build, install and keep running

## Hardware / software
| Item | Status on this Mac | Notes |
|---|---|---|
| macOS with **Xcode 16 or newer** (26 recommended) | **Missing** — only Command Line Tools installed | Install from the Mac App Store. ~15 GB free disk during install. Launch once, accept license, let it install the iOS platform when asked. Then `sudo xcode-select -s /Applications/Xcode.app` so `xcodebuild` works from the terminal. |
| iPad on **iPadOS 17+** | you have it | Any iPad that supports Pencil. |
| Apple Pencil | you have it | Any generation. Pencil Pro adds squeeze/hover — not used in v1. |
| USB-C / Lightning cable | — | Needed for the first install and for Developer Mode pairing. Afterwards Xcode can install over Wi-Fi. |
| Apple ID | — | See the signing decision below. **This is the one real decision you must make.** |

## Signing: free Apple ID vs paid Developer Program
This app is for daily personal use, so this matters more than usual.

| | Free Apple ID ("Personal Team") | Apple Developer Program, US$99 / year |
|---|---|---|
| App stops launching after | **7 days** — you must plug into Xcode and rebuild every week | 1 year (re-install once a year) |
| Max apps per device | 3 side-loaded | unlimited |
| Wi-Fi install from Xcode | yes | yes |
| TestFlight (install without a Mac) | no | yes — not needed for this project |
| Cost | 0 | 99/year |

**Recommendation:** paid. A note-taking app that dies every 7 days is exactly the kind of friction this project exists to remove. Enroll at developer.apple.com (takes 24–48 h to activate) while Xcode downloads.

## One-time device setup
1. iPad → Settings → Privacy & Security → **Developer Mode** → on → restart.
2. Connect iPad by cable; in Xcode → Window → Devices and Simulators → trust / pair; tick "Connect via network".
3. Xcode → Settings → Accounts → add your Apple ID (and select your team).

## Deploy: straight to the iPad over Wi-Fi (no TestFlight, no simulator)
TestFlight is not needed — it only matters for installing without a Mac nearby. The simulator has no
Pencil, so it is **only a compile check for agents**; every real test runs on the device.

```bash
sudo xcode-select -s /Applications/Xcode.app              # once
# once: connect iPad by cable → Xcode ▸ Window ▸ Devices and Simulators → tick "Connect via network" → unplug
xcrun devicectl list devices                              # note the iPad identifier

cd PenPDF
xcodebuild -project PenPDF.xcodeproj -scheme PenPDF \
  -destination 'id=<IPAD-ID>' -allowProvisioningUpdates \
  -derivedDataPath build build
xcrun devicectl device install app --device <IPAD-ID> \
  build/Build/Products/Debug-iphoneos/PenPDF.app
xcrun devicectl device process launch --device <IPAD-ID> com.yourname.penpdf
```
Or in the Xcode GUI: pick the iPad as destination, ⌘R. Either way the build lands on the iPad in seconds
over Wi-Fi. Agents may run the commands above after each work package so the owner can test immediately.

Compile-only check (what agents run when the iPad isn't reachable):
```bash
xcodebuild -project PenPDF.xcodeproj -scheme PenPDF -destination 'generic/platform=iOS Simulator' build
```

First run on the iPad: Settings → General → VPN & Device Management → trust your developer certificate.
In the target's Signing & Capabilities: "Automatically manage signing", your team, and a **unique bundle id**
(e.g. `com.yourname.penpdf`). That's the only project setting you personally touch.

**Reminder:** Wi-Fi deploy does not change the signing rule — with a free Apple ID the app stops launching
after 7 days until rebuilt from Xcode; with the paid program, after 1 year.

## Test documents to have in Files before WP3/WP4 testing
- A small text PDF (a paper, ~10 pages).
- A big scanned book (200+ pages, ≥ 200 MB).
- A vector-heavy PDF (a map / CAD export / dense slide deck).
- A PDF with rotated (landscape) pages mixed in.
- A password-protected PDF (for the P1 check).
- The same small PDF placed in **iCloud Drive** and in **On My iPad** — for the rename/move identity tests.

## Where your data lives (for backup / nuking)
`Files → On My iPad → PenPDF` is *not* where ink is. Ink and positions are inside the app container:
`Library/Application Support/PenPDF/Documents/<hash>/`. Deleting the app deletes them. iCloud/iTunes device backup includes them. (P2: an export.)

## Time estimate
- Agent implementation: WP0–WP5 ≈ 1 working day of agent time, spread across packages.
- Your time: ~30 min setup, then 3 test sessions of ~20 min on the iPad (after WP2, WP4, WP5).
