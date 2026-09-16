# PenPDF

A personal iPad app for reading PDFs and writing on them with Apple Pencil. It opens a PDF from
the Files app, renders it with PDFKit (Apple's own engine, the same one Preview uses), draws ink
with unmodified PencilKit, remembers exactly where you left off in every document, and never —
ever — jumps back to page 1 on its own. Single user (the owner), never shipped to the App Store.

## What it does

- **Open** — root screen is the system Files browser filtered to PDF; opening a PDF pushes the
  Reader full-screen. Cold launch with no incoming file reopens the last document directly. The
  original PDF file is never modified.
- **Read** — continuous vertical scrolling, fit-to-width by default, pinch to zoom, PDFKit text
  selection for free. The current page never changes because of a status-bar tap, nav-bar tap,
  rotation, Split View resize, backgrounding, or the tool palette showing/hiding.
- **Remember position** — page index (and, when you deliberately zoomed in, the zoom level and
  point on the page) is saved per document and restored before you ever see page 1. Identity is
  keyed by file content (a hash of size + head + tail bytes), so it survives rename, move, and
  iCloud eviction/re-download.
- **Ink** — every page has its own transparent PencilKit canvas floating above it
  (`PDFPageOverlayViewProvider`). Drawing is pencil-only — a resting finger or palm can never draw.
  Tools are the system `PKToolPicker` palette; undo/redo work on ink only. Ink is stored as native
  `PKDrawing` sidecar files next to the position data — it never touches the source PDF.
- **Lock ("paper mode")** — a toolbar toggle that makes the document ignore all finger input (no
  pan, pinch, scroll, or selection) while the Pencil keeps drawing normally and the toolbar's
  prev/next buttons keep navigating. Persisted globally across documents and relaunches.
- **Debug builds only** — an extra rightmost toolbar button (red when off) turns ink off so the
  Simulator's mouse (which the system treats as a finger) can scroll a page without drawing on it.
  It is compiled out of Release builds entirely and is never persisted.

See `spec/SPEC.md` for the full, authoritative product and architecture spec.

## Building and deploying

Full instructions, including the one real decision (free vs. paid Apple ID signing) and one-time
device setup, are in `spec/SETUP.md`. Short version:

```bash
sudo xcode-select -s /Applications/Xcode.app              # once

# Compile-only check (what agents run; the simulator has no Pencil so it is
# never a substitute for testing on the real device):
xcodebuild -project PenPDF.xcodeproj -scheme PenPDF \
  -destination 'generic/platform=iOS Simulator' build

# Real deploy, straight to the iPad over Wi-Fi (no TestFlight):
xcrun devicectl list devices                               # note the iPad identifier
xcodebuild -project PenPDF.xcodeproj -scheme PenPDF \
  -destination 'id=<IPAD-ID>' -allowProvisioningUpdates \
  -derivedDataPath build build
xcrun devicectl device install app --device <IPAD-ID> \
  build/Build/Products/Debug-iphoneos/PenPDF.app
xcrun devicectl device process launch --device <IPAD-ID> com.georgebuhanov.penpdf
```

Or just pick the iPad as the destination in Xcode and press ⌘R.

## Where your data lives

Everything PenPDF writes lives inside its own app container, never inside the source PDF and never
in `Files → On My iPad → PenPDF`:

```
<App Container>/Library/Application Support/PenPDF/Documents/<content-hash>/
    meta.json               position: page index, point, zoom, display name, page count
    page-000000.drawing     one PKDrawing sidecar per page that has ink (missing = no ink)
UserDefaults:
    PenPDF.lastDocumentBookmark   bookmark of the last opened document (for cold-launch reopen)
    PenPDF.isLocked                global Lock setting
```

Deleting the app deletes all of it. Device/iCloud backups include it. There is no export yet
(flattened-ink export is a possible P2, see `spec/notes/deferred.md`).

## Project layout

- `spec/SPEC.md` — authoritative product + architecture spec.
- `spec/WORK-PACKAGES.md` — the delegation plan the app was built from (WP0 → WP6).
- `spec/SETUP.md` — what the owner needs to build/sign/install.
- `spec/TEST-CHECKLIST.md` — device acceptance checklist.
- `spec/notes/deferred.md` — P1/P2 follow-ups and WP6 polish decisions.
- `PenPDF/App` — `AppDelegate`/`SceneDelegate` (scene config, URL routing, last-doc reopen).
- `PenPDF/Browser` — the Files-app-style document browser.
- `PenPDF/Reader` — `PDFView` host, toolbar, position restore/save, ink overlay, lock, undo/redo.
  `ReaderViewController.swift` holds stored properties, `init`/`deinit`, `loadView`, `viewDidLoad`,
  `viewDidAppear`, `viewDidLayoutSubviews`, `viewWillTransition`, and the toolbar actions; the rest
  is split into `ReaderViewController+Position.swift` (restore/save/page-change),
  `+Resize.swift` (rotation/resize settling window), `+Lock.swift` (lock-state application), and
  `+Ink.swift` (the `#if DEBUG` ink toggle) — a behaviour-neutral split done in WP6.
- `PenPDF/Storage` — document identity (content hash), per-document `meta.json` + ink store,
  last-opened-document bookmark, and the global Lock setting.

## Status

MVP complete (WP0–WP6). All functional work packages have been implemented and build clean
(Debug and Release, zero warnings from app code) against iOS 17 / iPad on the Simulator. Device
acceptance (`spec/TEST-CHECKLIST.md`, real iPad + real Pencil) is the remaining gate before calling
this "done" per `spec/SPEC.md` §9 — Simulator passes are necessary but not sufficient.
