# PenPDF — Work Packages & Delegation Plan

Companion to `SPEC.md`. Each package is sized for one implementing agent (cheaper model is fine).
The owner (or an orchestrating agent) runs them in order; parallel where marked.

## Ground rules for every implementer (paste into each prompt)

```
You are implementing one work package of PenPDF. Read spec/SPEC.md fully first; it is authoritative.
Rules:
1. Implement ONLY the package you were given. Touch ONLY the files it owns. Do not refactor others.
2. Do not add features, settings, gestures, animations, or "improvements" not in SPEC.md §3. If a P0
   seems to need something outside the spec, STOP and report; do not invent.
3. UIKit, programmatic, Swift 5 language mode, iOS 17, zero dependencies, no SwiftUI, no storyboards,
   no Core Data, no async/await required, no singletons beyond those in the module map.
4. Never change: drawingPolicy (.pencilOnly), the overlay-provider approach, sidecar storage,
   content-hash identity, scrollsToTop=false, the "restore before observing page changes" order.
5. After changes, the project must build:
   xcodebuild -project PenPDF.xcodeproj -scheme PenPDF \
     -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
   Report the result verbatim. If you cannot build (no Xcode), say so explicitly — do not claim success.
6. Finish with: files changed, what you verified, what you could NOT verify (device-only items),
   and any place where you had to interpret the spec.
```

## Dependency graph

```
WP0 skeleton ──▶ WP1 browser+open ──▶ WP2 reader render ──┬──▶ WP3 identity+position ──┐
                                                          ├──▶ S0 spike ──▶ WP4 ink ──┼──▶ WP5 lock ──▶ WP6 polish
                                                          └──────────────────────────┘
```
WP3 and (S0→WP4) can run in parallel after WP2. WP5 needs WP4 (it must prove Pencil still draws while locked).

---

## WP0 — Project skeleton
**Owns:** `PenPDF.xcodeproj/`, `PenPDF-Info.plist`, `PenPDF/App/*`, `PenPDF/Resources/*`, `.gitignore`, `README.md`
**Goal:** An empty UIKit app that builds and launches to a blank window on iPad simulator.

Tasks
- Create `PenPDF.xcodeproj` with a single iOS app target `PenPDF`, bundle id `com.<owner>.penpdf`, iPad-only (`TARGETED_DEVICE_FAMILY = 2`), deployment target 17.0, `SWIFT_VERSION = 5.0`, `GENERATE_INFOPLIST_FILE = NO`, `INFOPLIST_FILE = PenPDF-Info.plist`. Use an Xcode 16+ **synchronized folder** (`PBXFileSystemSynchronizedRootGroup`) pointing at `PenPDF/` so new files need no pbxproj edits. Include a shared scheme `PenPDF`.
- `PenPDF-Info.plist` must contain: `UIApplicationSceneManifest` (single scene, `UIApplicationSupportsMultipleScenes = NO`, delegate `$(PRODUCT_MODULE_NAME).SceneDelegate`), `UILaunchScreen = {}`, `UISupportsDocumentBrowser = YES`, `LSSupportsOpeningDocumentsInPlace = YES`, `UIFileSharingEnabled = YES`, `CFBundleDocumentTypes` for `com.adobe.pdf` (role Viewer, rank Alternate), `UISupportedInterfaceOrientations~ipad` all four.
- `AppDelegate.swift` (`@main`, scene config only) and `SceneDelegate.swift` (window + placeholder root VC; URL routing hooks stubbed).
- `Assets.xcassets` with an `AppIcon` set (a single flat-color 1024×1024 PNG is fine) and `AccentColor`.
- Reference: `spec/drafts/AppDelegate.swift`, `spec/drafts/SceneDelegate.swift` (align to spec; spec wins).

Acceptance
- `xcodebuild … build` succeeds with 0 errors.
- App launches on an iPad simulator to an empty window (no crash, no "no scene configuration" warning).

## WP1 — Browser & open
**Owns:** `PenPDF/Browser/BrowserViewController.swift`, `PenPDF/Storage/LastDocument.swift`, `SceneDelegate.swift` (routing only)
**Spec:** §3.1 FR-1…FR-5, §5.4 "Open" steps 1–3, §6.1 UserDefaults keys.

Tasks
- `BrowserViewController: UIDocumentBrowserViewController` for `[.pdf]`, creation off, multi-pick off. `openDocument(at:)` per §5.4: security scope → `PDFDocument(url:)` → remember bookmark → present a placeholder `ReaderViewController(fileURL:document:securityScoped:)` full-screen in a `UINavigationController` (WP2 replaces the placeholder). Failure → alert, stay, forget bookmark.
- `LastDocument.remember/resolve/forget` (bookmark data in UserDefaults; created while access is held).
- `SceneDelegate`: incoming `urlContexts` → open; else `LastDocument.resolve()` → open; `openURLContexts` → open.
- Reference: `spec/drafts/BrowserViewController.swift`, `spec/drafts/LastDocument.swift`.

Acceptance
- Pick a PDF in the simulator's Files → placeholder Reader appears with correct page count in title. Back returns to browser.
- Kill & relaunch → same document reopens without the browser (FR-5).
- Open a `.txt` renamed to `.pdf` → alert, browser remains.

## WP2 — Reader: rendering & position invariants
**Owns:** `PenPDF/Reader/ReaderViewController.swift`, `PenPDF/Reader/ReaderToolbar.swift`, `PenPDF/Reader/ResponderView.swift`
**Spec:** §3.2, §5.4 (Open steps 4–5, Page change, Rotation), §5.5, §7.

Tasks
- Full `ReaderViewController`: `loadView` → `ResponderView`; PDFView configured **exactly** as §5.5 (skip `pageOverlayViewProvider`/`isInMarkupMode` until WP4 — leave a clearly marked hook).
- Recursive `disableScrollsToTop(in:)`, called after `document` set and on every `viewDidLayoutSubviews`.
- Title `n / N` from `.PDFViewPageChanged`. Observation starts only after first layout (place the hook `restorePositionIfNeeded()` there — WP3 fills it; WP2 leaves it a no-op that still gates observation).
- Toolbar per §7 with all buttons present; lock / undo / redo / palette actions are no-op stubs with `// WP4` / `// WP5` markers; prev/next page work now via `pdfView.goToNextPage/goToPreviousPage`.
- `viewWillTransition` capture/restore of `currentDestination`.
- Back button: dismiss; `deinit` stops security-scoped access.

Acceptance
- Scroll to page 40, tap status bar → still page 40. Rotate → still page 40. Enter Split View → still page 40.
- Zoom, pan, long-press-select text all work with a finger.
- No custom gesture recognizers added anywhere.

## WP3 — Identity & position persistence
**Owns:** `PenPDF/Storage/DocumentIdentity.swift`, `PenPDF/Storage/DocumentStore.swift` (position half), `ReaderViewController.restorePositionIfNeeded()` / `savePosition()`
**Spec:** §3.3, §6.2, §6.3, §5.4 Open step 5 & Page change & Flush.

Tasks
- `DocumentIdentity.key(for:)` exactly per §6.2. Reference `spec/drafts/DocumentIdentity.swift`.
- `DocumentStore(key:)`: folder creation; `meta.json` Codable read/write (atomic); `loadPosition() -> Position?`, `savePosition(_:)` with 1 s debounce + `flush()`.
- Reader: restore in first `viewDidLayoutSubviews` **before** starting page-change observation; `go(to: PDFDestination)` for page+point; zoom restore (P1) may be a TODO but page index must work.
- Flush on `willResignActive`, `didEnterBackground`, back button, `deinit`.

Acceptance
- Open, scroll to page 57, kill app from switcher, relaunch → first visible frame is page 57 (record screen to confirm no page-1 flash).
- In Files: rename the PDF, move it to another folder → reopen → page 57.
- Two different PDFs remember independent positions.
- Unit test (XCTest, simulator): identity key identical for a file and a renamed copy; different for a file with one byte changed.

## S0 — Spike: overlay geometry (30 min, throwaway)
**Owns:** nothing permanent. **Blocks WP4.**
Prove on simulator: with a bare `PDFPageOverlayViewProvider` returning a `PKCanvasView` (policy `.anyInput` in simulator) and **no frame/transform management**, ink drawn at 100 % stays glued to page content at 50 % and 300 % zoom, after rotation, and after scrolling the page off and back on. Also check `isInMarkupMode` exists in the SDK and what it changes.
Output: a short note in `spec/notes/S0-overlay-geometry.md`: pass/fail per case, and if PDFKit does *not* manage geometry, the exact transform WP4 must apply. WP4 must follow that note.

## WP4 — Ink
**Owns:** `PenPDF/Reader/InkOverlayCoordinator.swift`, `PenPDF/Reader/PageCanvasView.swift`, `DocumentStore` (ink half), Reader hooks for palette/undo/redo
**Spec:** §3.4, §5.4 (Overlay, Stroke, Flush), §5.6, §6.4, S0 note.

Tasks
- `PageCanvasView` per §5.6 (+ simulator-only `.anyInput`).
- `InkOverlayCoordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate`: live canvas map, `PKToolPicker` ownership, `addObserver/removeObserver` on create/recycle, drawing load/save through `DocumentStore`.
- `DocumentStore` ink half: `drawing(forPage:)`, `update(_:forPage:)`, debounced write, empty-drawing ⇒ delete file, `flush()`. Reference `spec/drafts/DocumentStore.swift`, `spec/drafts/PageCanvasView.swift`.
- Reader: set `pageOverlayViewProvider` and `isInMarkupMode` (if available); `viewDidAppear` → tool picker visible for `view`, `view.becomeFirstResponder()`; palette button toggles `setVisible`; undo/redo → the undo manager the canvases resolve to (verify which — `view.window?.undoManager` vs `canvas.undoManager` — and document it in code).
- Flush includes pushing every live canvas's drawing to the store.

Acceptance (simulator with mouse, then device — see checklist)
- Draw on pages 1, 2, 50; scroll far away and back → ink present. Kill & relaunch → ink present, correctly aligned at any zoom.
- Erase everything on a page → its `.drawing` file is deleted.
- Undo/redo work across at least the current page. Palette toggles.
- On device: a finger on the page never draws (FR-17), even with the system "Only Draw with Apple Pencil" off.

## WP5 — Lock mode (+ two Reader fixes found in WP2/WP3 device testing)
**Owns:** `PenPDF/Reader/InteractionLock.swift`, `PenPDF/Storage/AppSettings.swift`, `PenPDF/Reader/ReaderTitleView.swift`, Reader lock button wiring, Reader `viewWillTransition`
**Spec:** §3.5, §5.7, FR-9, §5.4 "Rotation / resize".

Fixes carried into this package (owner-reported on simulator, 2026-09-15):
- F1 **Resize/rotation lands on the last page.** Root cause: WP2 re-applies the raw `currentDestination`; its point can be PDFKit's unspecified-value garbage. Implement §5.4 "Rotation / resize" as now written (sanitized point or page-only, plus one deferred re-apply).
- F2 **Title = file name + thumbnail** per updated FR-9/§7, in a new `ReaderTitleView` (two labels + 22-pt image view; `PDFPage.thumbnail(of:for:)` for page 0, rendered once off the main path or lazily).

Tasks
- `AppSettings.isLocked` (UserDefaults).
- `InteractionLock` primary approach per §5.7 steps 1–5; re-apply on layout while locked.
- Toolbar: lock icon state, prev/next visible/enabled while locked, apply on `viewDidLoad` from settings.

Acceptance (device)
- Locked: rest a palm and drag fingers across the page in every direction → nothing moves, nothing selects, nothing zooms. Pencil draws normally. Prev/next buttons change page. Palette still opens.
- Unlock → all finger gestures back. Toggle state survives relaunch and switching documents.
- If primary approach fails, fallback per §5.7 implemented and the reason written in `spec/notes/WP5-lock.md`.

## WP5b — Palette button + debug ink toggle (FR-18a) — DONE 2026-09-15 (by the orchestrator)
✎ = palette show/hide only (Preview behaviour). `#if DEBUG` rightmost `pencil.slash` button toggles ink off for simulator scrolling; compiled out of Release (verified with a Release build).

## WP5c — Resize settling window (F1, second fix) — DONE 2026-09-15 (by the orchestrator)
First fix (one-shot re-pin + one deferred re-pin) was insufficient: owner still saw page 1–2 then 12 on repeated window resizes. Replaced by the settling-window design now in SPEC §5.4 "Rotation / resize". Owner to re-test: rotate / resize back and forth repeatedly → page never changes; `meta.json` never records a transient page.

## WP6 — Polish & handoff — DONE 2026-09-15 (crispness experiment awaiting owner verdict)
**Owns:** `README.md`, icon, `spec/notes/*`
- Real (still simple) app icon. Verify dark mode background colors. Confirm no console warnings on launch.
- Run the complete `TEST-CHECKLIST.md` with the owner; fix P0 failures; log P1/P2 deferrals in `spec/notes/deferred.md`.

---

## P1 follow-ups (separate packages later)
- FR-6 password prompt · FR-14 point+zoom restore · pencil-double-tap-to-lock (respecting system setting) · P2 flattened export via share sheet.

## WP7 — Full-bleed glass bar (FR-31) — DONE 2026-09-15 (`.always` worked first try; no revert)
**Owns:** Reader `viewDidLoad` constraints, the recursive scroll-view walk (`contentInsetAdjustmentBehavior`), `setContentScrollView` registration.
Per SPEC §7 "Full-bleed under a glass bar". Behaviour risk: PDFKit destinations vs. adjusted insets — re-run B1–B8 and the resize test on the simulator; owner confirms visually that the page shows through under the bar and page 1 starts below it.


## S1 — Crisp ink at zoom — FAILED 2026-09-15, flag off
PencilKit-native `zoomScale` + `1/z` counter-transform rendered sharp but drifted during pinch and flew off the page after repeated large zooms. `InkOverlayCoordinator.crispZoomEnabled = false` (baseline geometry, ink soft at high zoom). Do not retry without a new owner decision; see `spec/notes/deferred.md`.

## Status summary (2026-09-15, end of simulator phase)
WP0–WP7 done and owner-accepted on the simulator. Open: device-only tests (`TEST-CHECKLIST.md` sections C10, D, E, F) once Apple frees device slots; P1s in `deferred.md`; ✎ semantics decision after device use.

## S2 — Option B crisp ink — ACCEPTED on simulator & MERGED to main 2026-09-16 (device regression check pending)
Owner: "crispness, position, writing feel perfect — same quality as Preview." Two fixes during acceptance (hit-test/mask; pen-up render ordering) logged in the note.
Design and acceptance in `spec/notes/S2-option-b-crisp-ink.md`. Owns: `PenPDF/Reader/PageOverlayView.swift` (new), `InkOverlayCoordinator.swift` (return the overlay container; render pipeline; tool begin/end + drawing-change hooks), Reader `.PDFViewScaleChanged` hook. Merges to `main` only after owner acceptance on simulator AND iPad.

## Milestone — simulator phase closed 2026-09-16
Owner on `main` @ `cddb6ab`+: "works beautifully — core functionality nailed." All P0 packages plus S2 crisp ink accepted on the simulator. Next: device regression (`TEST-CHECKLIST.md` C10, D, E, F) when Apple frees device slots; then features from the P1 list below, in the order the owner picks.

### Feature backlog (P1, owner to prioritise after device run)
- FR-29 Export with ink (flattened copy via share sheet) — only if the owner needs notes visible outside PenPDF.
- FR-6 Password-protected PDFs (prompt once).
- FR-14 Point-in-page restore at fit width (currently page-level at fit, point-level when zoomed in).
- Lock default-on / Pencil double-tap (system-setting-respecting) to toggle Lock — decide after palm test D2/E1.
- ✎ semantics: keep palette-only, or Preview-style ink on/off in all builds — decide on device.
- Search / outline are non-goals unless the owner reopens them.
