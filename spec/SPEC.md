# PenPDF — Product & Architecture Spec

**Status:** v1.0 — authoritative. If code, a draft, or a work-package prompt disagrees with this file, this file wins.
**Audience:** implementing agents and the owner. Read fully before writing any code.

---

## 0. One paragraph

A personal iPad app that opens a PDF from the Files app, renders it as fast as Apple's own Preview,
lets me write on it with Apple Pencil using Apple's own low-latency ink (PencilKit), ignores my hand
completely, remembers exactly where I was in every document, and never — ever — jumps to page 1 on
its own. Nothing else. It is for one user (the owner) and is never shipped to the App Store.

## 1. Why this app exists (the pain it fixes)

These are the owner's actual complaints. Every one is a hard requirement, not a nice-to-have.

| # | Pain in Preview / Notability | What we do instead |
|---|---|---|
| P1 | Palm rejection barely works — a resting hand **pans and zooms** the page (the owner had already disabled finger drawing system-wide; stray marks were never the main issue). | Ink is **pencil-only** at the API level (finger can never draw). **Two-finger pan** (FR-32) so a palm's single touch can't move the page, like Notability. Plus an explicit **Lock** mode that makes the document inert to fingers entirely, like paper. |
| P2 | Does not remember the last opened page. | Position is saved per document, keyed by **file content**, not path. Restored on every open, including after rename/move/iCloud eviction. |
| P3 | Tapping the top bar / status bar scrolls to page 1. Losing the page is the worst thing the app can do. | `scrollsToTop` disabled on **every** scroll view in the hierarchy. No gesture, rotation, or layout event may change the current page. |
| P4 | Notability uses its own ink engine, feels off. | We use **PencilKit** unmodified. Zero custom stroke code. |
| P5 | Feature bloat. | Explicit non-goals list (§4). Anything not in §3 is out. |

## 2. Users, platform, distribution

- Single user: the owner. No accounts, no sync, no analytics, no onboarding.
- **iPad only**, iPadOS **17.0+**. Not iPhone, not Mac Catalyst.
- Apple Pencil (any generation). Finger is for navigation only.
- Installed by the owner via Xcode onto their own iPad. Never App Store. See `SETUP.md`.
- Ships in English only, no localization infrastructure.

## 3. Functional requirements

Priority: **P0** = MVP must-have; **P1** = do after P0 is verified on device; **P2** = later / maybe never.

### 3.1 Opening documents (P0)
- FR-1 The app's root screen is the system document browser (`UIDocumentBrowserViewController`) filtered to PDF. Document creation is disabled.
- FR-2 The app appears in Files' "Open With" / share sheet for PDFs and opens the file **in place** (no import copy).
- FR-3 Opening a PDF presents the Reader full-screen over the browser. A single "back" control returns to the browser.
- FR-4 The original PDF file is **never modified**. The app holds it read-only. All app state lives in the app's own container.
- FR-5 (P1) On cold launch with no incoming URL, the app reopens the **last opened document** directly, skipping the browser. If it can't be resolved, fall back to the browser silently.
- FR-6 (P1) Password-protected PDFs: prompt for the password once; on failure return to browser.

### 3.2 Reading (P0)
- FR-7 Continuous vertical scrolling, single page column, pages fit width by default (like Preview). Pinch to zoom, one-finger pan.
- FR-8 Rendering via PDFKit. Must feel as smooth as Preview on the same document. No custom renderer.
- FR-9 Title area (a custom `titleView`) shows, like Preview: a small first-page thumbnail (or `doc.text` symbol if rendering fails) + the file name (without extension) on the top line, and `currentPage / pageCount` on a second, smaller line — live-updating as you scroll. Nothing in the title is tappable.
- FR-10 **Position invariants** — the current page must NOT change as a result of any of: status-bar tap, nav-bar tap, device rotation, Split View / Stage Manager resize, app backgrounding & foregrounding, tool palette showing/hiding, Lock toggling. Rotation/resize re-fit the zoom but keep the same page (and as close as possible the same point on it).
- FR-31 (P1) Full-bleed under a glass navigation bar — see §7.
- FR-32 (P0, added 2026-09-16 after device test D2) **Two-finger navigation.** A single finger never pans the page — a resting palm is one large single-touch and it drifted the page exactly as in Preview. Notability's model: pan requires **two fingers**; pinch stays two-finger; single-finger tap/long-press may still select text (FR-11). Implemented by setting `minimumNumberOfTouches = 2` on every `UIScrollView.panGestureRecognizer` under `pdfView` in the same recursive walk that sets `scrollsToTop = false` (re-applied on every layout, PDFKit may recreate internals). Lock mode (§3.5) is unchanged and still the total-immunity option. Backup if two-finger alone still drifts under a heavy palm: pen-down auto-lock (disable pan/pinch from `didBeginUsingTool` to ~300 ms after `didEndUsingTool`).
- FR-11 Text selection: whatever PDFKit gives for free with finger long-press. Do not build anything for it. Disabled while Locked (§3.5).

### 3.3 Remembering position (P0)
- FR-12 On every page change, the reading position is saved (debounced ≤ 1 s) and also saved immediately on: Reader close, app resign-active, scene background.
- FR-13 On open, the position is restored **before the user can see page 1**. Acceptable: the first visible frame is the restored page. Not acceptable: seeing page 1 then jumping.
- FR-14 Position = page index (P0) + point on page + zoom relative to fit-width (P1). Stored per document identity (§6.2).
- FR-15 Identity survives: rename, move to another folder, move between iCloud Drive / On My iPad / external drive, iCloud evict & re-download. It does NOT need to survive the PDF's bytes changing (that's a different document).

### 3.4 Ink (P0)
- FR-16 Each page has its own transparent PencilKit canvas floating above it (PDFKit page overlay). Ink is drawn with the system PencilKit pipeline. **No custom stroke rendering, ever.**
- FR-17 Drawing policy is **pencil only**. A finger on the canvas never draws, regardless of the system "Only Draw with Apple Pencil" setting.
- FR-18 Tools: the system `PKToolPicker` palette (pen, marker, pencil, eraser, lasso, ruler, colors). No custom tool UI.
- FR-18a The ✎ button shows/hides the palette and nothing else (Preview behaviour). **Debug builds only** (`#if DEBUG`, absent from Release): an extra rightmost button (`pencil.slash`, red when off) toggles ink off — `pdfView.isInMarkupMode = false`, live canvases `isUserInteractionEnabled = false` — so the simulator's mouse (treated as a finger under `anyInput`) can scroll without drawing. Default on at every launch; not persisted.
- FR-19 Undo / Redo buttons in the toolbar, operating on ink only. Apple Pencil double-tap behaves as the system setting says (default: switch to eraser) — do not override.
- FR-20 Ink is persisted per page as native `PKDrawing` data in the app container (§6.3). Saved: debounced ≤ 1.5 s after a stroke, when a page's canvas is recycled off-screen, on Reader close, on resign-active/background. Ink loss is a P0 bug.
- FR-21 Ink stays registered to the page content at every zoom level, after rotation, after relaunch. Drift of ink relative to page is a P0 bug.
- FR-22 Ink is a sidecar; it is never written into the PDF in v1. (P2: export a flattened copy via share sheet.)

### 3.5 Lock mode (P0) — "paper mode"
- FR-23 A toolbar toggle **Lock**. When ON, the document area ignores **all finger input**: no pan, no pinch, no scroll, no tap-to-select, no long-press. The Pencil still draws normally. The toolbar remains fully usable (by finger or Pencil).
- FR-24 While locked, navigation is via **Previous page / Next page** toolbar buttons (they appear only when locked, or are always present — implementer's call; must exist when locked).
- FR-25 Lock state is clearly visible (filled lock icon + tinted toolbar button). It is a global, persisted setting: remains ON across documents and relaunches until the owner turns it off.
- FR-26 The lock control must not be reachable by a resting palm: it lives in the top toolbar, never floating over the page.

### 3.6 Non-functional
- NFR-1 Cold launch to restored page on a 100-page text PDF: < 1.5 s on an M-series iPad.
- NFR-2 Pencil latency: indistinguishable from Apple Notes (we use the same pipeline; any regression means we broke the pipeline — e.g. by putting a canvas inside a transformed/rasterised layer).
- NFR-3 A 300-page scanned PDF (≥ 200 MB) scrolls without visible stutter and does not get the app killed for memory.
- NFR-4 Zero third-party dependencies. Zero network access. No Info.plist privacy permissions needed.
- NFR-5 Works offline, works in Split View, both orientations.

### 3.7 Interoperability with Preview / Markup ink
- FR-27 (P0) Ink that already exists **inside** a PDF (Preview, Files Markup, other apps store strokes as `Ink` annotations) must render exactly as PDFKit renders it by default. Never set `displaysAnnotations = false` on pages or hide annotations. PenPDF's own ink layer draws above it.
- FR-28 (v1 limitation, by design) Pre-existing in-file ink is not editable/erasable in PenPDF; PenPDF's ink is not visible to Preview because it is a sidecar (§5.1). Both are accepted trade-offs for speed and never touching the source file.
- FR-29 (P2) "Export with ink": share-sheet action producing a **copy** of the PDF with PenPDF strokes flattened in as `Ink` annotations, so Preview and others see them. The original stays untouched.
- FR-30 (P1, promoted 2026-09-16) **Adopt Preview ink.** Device finding: Preview's baked-in strokes render as a low-res bitmap at every zoom (their appearance stream is rasterised at write time). Import them into the editable sidecar layer so they become crisp and editable: first choice, decode the PencilKit payload Apple stores alongside the `Ink` annotation (inspect a real file first — private format, may change; guard with a version check and a fallback); fallback, convert annotation ink paths to `PKStroke`s (public API, loses pressure). After import, suppress rendering of the adopted annotations (`PDFAnnotation.shouldDisplay` / page-level filtering) so they are not shown twice. The file itself is never modified.
- All frameworks are public Apple SDKs only: UIKit, PDFKit, PencilKit, UniformTypeIdentifiers, CryptoKit. No private API. No third-party code.

## 4. Non-goals (do not build, do not "prepare for")

Handwriting recognition · OCR · search · bookmarks/outline · page thumbnails · annotations other than ink (highlights, text boxes, shapes) · form filling · signatures · sharing/export (P2 only, see FR-29) · editing ink that is baked inside the PDF (see FR-28) · cloud sync · multi-window/multiple scenes · iPhone · settings screen · onboarding · custom themes · custom pen UI · gestures beyond system defaults · iCloud key-value sync of positions · any analytics.

If an implementer thinks something here is needed to satisfy a P0, they stop and ask; they do not add it.

## 5. Architecture

### 5.1 Stack — fixed decisions
| Decision | Choice | Why (and why not the alternative) |
|---|---|---|
| UI framework | **UIKit, programmatic**, no storyboards, no SwiftUI | PDFKit's overlay provider and PencilKit's tool picker are UIKit-first; SwiftUI wrappers add a bridging layer that hurts exactly the latency we care about. |
| Language mode | **Swift 5** (`SWIFT_VERSION = 5.0`), iOS 17 deployment target | Avoids Swift 6 strict-concurrency friction in delegate/notification code. Everything is main-thread anyway. |
| PDF rendering | **PDFKit** (`PDFView`) | Same engine as Preview. Gives scrolling, zoom, selection, tiling, caching for free. PDFium/MuPDF only if PDFKit proves too slow on the owner's real documents — not before. |
| Ink | **PencilKit** (`PKCanvasView`, `PKDrawing`, `PKToolPicker`) | Only way to get Apple's private low-latency pencil pipeline. |
| Ink ↔ PDF composition | **`PDFPageOverlayViewProvider`** (iOS 16+) — one `PageOverlayView` per visible page = live `PKCanvasView` (full drawing, masked out when idle) + `UIImageView` of the settled strokes rendered by `PKDrawing.image(from:scale:)` at the current zoom | Apple's sanctioned way to put PencilKit over PDFKit. The image layer exists because a `PKCanvasView` magnified by PDFKit's ancestor transform is bitmap-blurry and Apple DTS confirms no workaround; a bitmap layer honours `contentsScale`, so settled ink is crisp at any zoom while the live stroke keeps PencilKit's latency untouched. Design/acceptance: `spec/notes/S2-option-b-crisp-ink.md`. Not `PDFAnnotation` ink (writes the file, loses pen fidelity). |
| Ink storage | Sidecar `PKDrawing` blobs per page in Application Support | Lossless, vector, fast. Never touches the source PDF. |
| Document identity | SHA-256 of (file size ∥ first 64 KB ∥ last 64 KB) | Path-independent (FR-15). ~1 ms. |
| Position storage | `meta.json` per document folder | Lives next to the ink; deleting a folder cleans everything for that document. |
| Persistence framework | Plain files + `Codable` + `UserDefaults` for global flags | Core Data / SwiftData is bloat here. |
| Scenes | Single scene (`UIApplicationSupportsMultipleScenes = NO`) | Removes a whole class of "which window has the tool picker" bugs. |

### 5.2 Module map

```
PenPDF/                          (Xcode target, synchronized folder)
├─ App/
│  ├─ AppDelegate.swift            @main; scene configuration only
│  └─ SceneDelegate.swift          window, root = BrowserViewController, URL routing, last-doc reopen
├─ Browser/
│  └─ BrowserViewController.swift  UIDocumentBrowserViewController subclass; open(url) → Reader
├─ Reader/
│  ├─ ReaderViewController.swift   PDFView host, toolbar, position restore/save, lock, undo/redo
│  ├─ ReaderToolbar.swift          builds UIBarButtonItems; no logic (optional file)
│  ├─ InkOverlayCoordinator.swift  PDFPageOverlayViewProvider + PKCanvasViewDelegate; owns live canvases + PKToolPicker
│  ├─ PageCanvasView.swift         PKCanvasView subclass (pageIndex, canBecomeFirstResponder=false)
│  ├─ PageOverlayView.swift        container returned to PDFKit: masked live canvas + crisp settled-ink image (S2)
│  ├─ ResponderView.swift          UIView with canBecomeFirstResponder=true (tool picker anchor)
│  └─ InteractionLock.swift        enables/disables finger gesture recognizers on PDFView tree
├─ Storage/
│  ├─ DocumentIdentity.swift       content hash → key
│  ├─ DocumentStore.swift          per-document folder: meta.json (position) + page-NNNNNN.drawing
│  ├─ LastDocument.swift           bookmark of last opened URL (UserDefaults)
│  └─ AppSettings.swift            isLocked (UserDefaults)
└─ Resources/
   └─ Assets.xcassets              AppIcon (any placeholder), AccentColor
PenPDF-Info.plist                (outside the synchronized folder — see WP0)
```

Rules: one type per file where practical; no file > 300 lines; no singletons except `AppSettings`/`LastDocument` static helpers; no global mutable state.

### 5.3 Object graph & lifecycle

```
SceneDelegate ──owns──▶ UIWindow ──root──▶ BrowserViewController
                                                │ openDocument(at: url)
                                                ▼ presents full-screen
                                   UINavigationController(ReaderViewController)
ReaderViewController
  ├─ fileURL, securityScoped: Bool          (startAccessing on open; stopAccessing in deinit)
  ├─ pdfDocument: PDFDocument
  ├─ store: DocumentStore                   (key = DocumentIdentity.key(fileURL))
  ├─ pdfView: PDFView
  ├─ ink: InkOverlayCoordinator             (pdfView.pageOverlayViewProvider = ink)
  ├─ lock: InteractionLock                  (lock.apply(to: pdfView, locked: AppSettings.isLocked))
  └─ view: ResponderView                    (first responder → PKToolPicker anchor)
InkOverlayCoordinator
  ├─ toolPicker: PKToolPicker               (one per Reader)
  ├─ liveCanvases: [pageIndex: PageCanvasView]
  └─ store: DocumentStore                   (drawing(forPage:), update(_:forPage:))
```

### 5.4 Critical sequences

**Open**
1. Browser: `scoped = url.startAccessingSecurityScopedResource()`; `PDFDocument(url:)` (mmap path — never `Data(contentsOf:)`). If nil → stop access, alert, stay in browser.
2. `LastDocument.remember(url)` (bookmark, created while access is held).
3. Push Reader with `(url, document, scoped)`.
4. Reader `viewDidLoad`: configure `pdfView` (§5.5), set `document`, **do not** observe page changes yet.
5. Reader `viewDidLayoutSubviews` (first time `view.bounds` non-empty and `pdfView.document != nil`): apply `disableScrollsToTop` (recursive), restore position (`go(to:)`), THEN start observing `.PDFViewPageChanged`. Set `hasRestoredPosition = true`.
   - Rationale: PDFKit posts a page-changed notification for page 0 during initial layout. Observing before restore overwrites the saved position with 0. This is the #1 way to break FR-13.
6. `viewDidAppear`: `toolPicker.setVisible(true, forFirstResponder: view)`; `view.becomeFirstResponder()`.

**Page change** → update title; debounce 1 s → `store.savePosition(currentDestination)`.

**Overlay for page** (called by PDFKit as pages come on screen)
1. `index = document.index(for: page)`; guard `!= NSNotFound`.
2. Reuse the live `PageOverlayView` or create one wrapping a new `PageCanvasView` (§5.6) with `drawing = store.drawing(forPage: index)`, `toolPicker.addObserver(canvas)`; kick off the settled-ink image render.
3. Return the overlay container. **Do not set its frame** — PDFKit owns geometry. The single exception is the crisp-zoom counter-transform (`spec/notes/deferred.md`, spike S1): `zoomScale = z` plus `transform = scale(1/z)`, which leaves the on-screen frame untouched while PencilKit renders at true resolution.

**Overlay ends display** → `store.update(canvas.drawing, forPage: index)`; `toolPicker.removeObserver(canvas)`; remove from `liveCanvases`.

**Off-screen handling (memory model).** PDFKit owns page-view and tile recycling — do not pre-render, cache, or snapshot pages yourself. Canvases (GPU-backed) exist only for pages PDFKit is displaying; drawings (vector, small) may stay in `DocumentStore`'s in-memory dictionary for the Reader's lifetime. The **only** sanctioned optimization if test C11 shows a hitch when scrolling back to an ink-heavy page: keep an LRU of at most ±2 recently-displayed canvases warm inside `InkOverlayCoordinator` instead of discarding on `willEndDisplaying`. Nothing else.

**Stroke** (`canvasViewDrawingDidChange`) → `store.update(drawing, forPage: canvas.pageIndex)` (store debounces disk write).

**Flush everything** (on `willResignActive`, `didEnterBackground`, Reader close, `deinit`): push all live canvases' drawings to store; save position now; `store.flush()`.

**Rotation / resize** (`viewWillTransition(to:with:)`) — implemented as a *settling window*, not a one-shot re-pin. PDFKit's `autoScales` re-layout is asynchronous and clamps the scroll offset (→ last page or page 1) after the transition coordinator completes and after the next run-loop turn. So: at the start of the first resize capture `resizePin = (currentPage, sanitized point or nil)` (never re-capture while a window is open — the page mid-resize is transient); re-apply `go(to:)` on the transition completion, on every `.PDFViewScaleChanged`, and on every `viewDidLayoutSubviews` where `currentPage !== pin.page`; while the window is open **suppress `savePosition`**; 0.4 s after the last signal pin once more, clear the window, refresh the title, resume saves. Point sanitization: finite and inside the crop box — PDFKit's `kPDFDestinationUnspecifiedValue` garbage otherwise lands `go(to:)` on the LAST page.

### 5.5 PDFView configuration (exact)
```swift
pdfView.displayMode = .singlePageContinuous
pdfView.displayDirection = .vertical
pdfView.usePageViewController(false)
pdfView.autoScales = true
pdfView.pageShadowsEnabled = false          // measurable cost, zero value
pdfView.interpolationQuality = .high        // .low is the perf knob if scanned docs stutter
pdfView.backgroundColor = .secondarySystemBackground
pdfView.pageOverlayViewProvider = ink
pdfView.isInMarkupMode = true                // routes Pencil to overlays; verify availability in SDK, iOS 16+
pdfView.document = pdfDocument
```
Then recursively for every `UIScrollView` under `pdfView`: `scrollsToTop = false`. Repeat on every `viewDidLayoutSubviews` (cheap; PDFKit may recreate internals).

### 5.6 PageCanvasView configuration (exact)
```swift
canvas.drawingPolicy = .pencilOnly       // FR-17 — the palm fix. Never .default, never .anyInput in release.
canvas.backgroundColor = .clear
canvas.isOpaque = false
canvas.isScrollEnabled = false           // PKCanvasView IS a UIScrollView; PDFView owns panning
canvas.scrollsToTop = false              // FR-10
canvas.contentInsetAdjustmentBehavior = .never
canvas.pageIndex = index
canvas.delegate = coordinator
canvas.tool = toolPicker.selectedTool
```
`canBecomeFirstResponder` returns `false` — the tool picker is anchored to `ResponderView`; a canvas grabbing first responder mid-stroke hides the palette.

Simulator only (`#if targetEnvironment(simulator)`): `drawingPolicy = .anyInput` so a mouse can draw for smoke testing. Never on device.

### 5.7 Lock mode implementation (`InteractionLock`)
Primary approach — deterministic, no hit-test tricks:
1. Walk `pdfView` and all descendants. For every view that is **not** a `PKCanvasView` (or inside one), collect its `gestureRecognizers`. Store `(recognizer, wasEnabled)`.
2. Lock ON: set each collected recognizer `isEnabled = false`; set every `UIScrollView` (again excluding canvases) `isScrollEnabled = false`; `pinchGestureRecognizer?.isEnabled = false`.
3. Lock OFF: restore recorded `isEnabled` values; `isScrollEnabled = true`.
4. Re-apply on every `viewDidLayoutSubviews` while locked (PDFKit may add recognizers lazily).
5. Programmatic navigation (`go(to:)`, prev/next buttons) must still work while locked — it does, since it doesn't go through gestures.

Fallback if PDFKit misbehaves: a transparent `TouchShield` view over the PDFView that overrides `hitTest` to return itself for `.direct` touches and `nil` for `.pencil`. Only if the primary fails on device — document why.

Pencil touches on the canvases are untouched by lock; drawing continues to work.

## 6. Data

### 6.1 Locations
```
<App Container>/Library/Application Support/PenPDF/Documents/<key>/
    meta.json
    page-000000.drawing
    page-000012.drawing            (only pages that have ink; empty drawing ⇒ file deleted)
UserDefaults:
    PenPDF.lastDocumentBookmark    Data     (bookmark of last opened URL)
    PenPDF.isLocked                Bool
```

### 6.2 `key` — DocumentIdentity
`hex(SHA256( UInt64(fileSize).littleEndian ∥ bytes[0 ..< min(64K, size)] ∥ (size > 128K ? bytes[size-64K ..< size] : ∅) ))`.
Computed once per open, while security-scoped access is held. If the file can't be read, fall back to `SHA256(lastPathComponent)` and log it.

### 6.3 `meta.json`
```json
{
  "formatVersion": 1,
  "displayName": "Paper.pdf",
  "pageCount": 128,
  "lastPageIndex": 11,
  "lastPoint": { "x": 0, "y": 612.5 },
  "lastZoomRelativeToFit": 1.0,
  "updatedAt": "2026-09-15T10:12:33Z"
}
```
`lastPageIndex` is P0; the rest P1. Reader must tolerate missing optional fields. Write atomically.

### 6.4 Ink files
`PKDrawing.dataRepresentation()` verbatim. Coordinates are in the overlay view's coordinate space as PDFKit presents it (unrotated page points). Do not transform on save/load. (Only a future flattened-export feature needs to care about `/Rotate`.)

## 7. UI

Preview-like, minimal. One `UINavigationBar`, standard height, no large titles, system materials, dark mode via system colors only.

**Full-bleed under a glass bar (FR-31, added 2026-09-15).** The document extends beneath the navigation bar like Preview: `pdfView` is pinned to the root view's top/bottom edges (leading/trailing to the safe area); the bar keeps the system default (iOS 26 Liquid Glass, transparent background with floating pill items — do not set custom opaque appearances). PDFKit's internal `UIScrollView` gets `contentInsetAdjustmentBehavior = .always` (applied in the same recursive walk as `scrollsToTop`) so page 1 begins below the bar and the palette never covers the last page; the Reader also registers that scroll view via `setContentScrollView(_:for: .top)` so the navigation controller applies its scroll-edge effect. Acceptance: all §3.2 position invariants and the restore test (B8) still pass — PDFKit destinations must respect the adjusted inset, i.e. a restored page's top edge sits just below the bar, not under it. If PDFKit fights the inset (page tops land under the bar, `go(to:)` off by the bar height), revert to safe-area pinning and record why in `spec/notes/WP7-glass-bar.md`.

```
┌──────────────────────────────────────────────────────────────┐
│ ‹ Files     [▫] Paper-name                 🔒  ◁  ▷   ↶  ↷   ✎      │  ← nav bar
│                 12 / 128                                     │     (thumb + name / counter)
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                     PDF page (fit width)                     │
│                     + PencilKit overlay                      │
│                                                              │
│                        [ PKToolPicker floating palette ]     │  ← system-provided
└──────────────────────────────────────────────────────────────┘
```
- `‹ Files` back → flush, dismiss, stop security-scoped access.
- Title view: thumbnail + file name, counter `12 / 128` beneath, live (FR-9).
- `🔒` Lock toggle (filled when on, tinted). `◁ ▷` prev/next page (visible when locked; may be always visible). `↶ ↷` undo/redo. `✎` show/hide palette. Debug builds add a rightmost `pencil.slash` ink-off button (FR-18a).
- No bottom bar. No floating buttons over the page. No gestures added by us.

## 8. Error handling
- Unreadable / non-PDF → alert in browser, stay in browser, forget last-document bookmark.
- Locked PDF → password alert (P1); cancel → browser.
- Ink or meta write failure → retry once on next flush; never crash; `os_log` error.
- Missing `meta.json` → open at page 0 (this is the only legitimate way to land on page 1).

## 9. Definition of Done (MVP)
All P0 FRs implemented **and** every P0 item in `TEST-CHECKLIST.md` ticked by the owner on a real iPad with a real Pencil. Simulator passes are necessary but not sufficient.
