# PenPDF — read this first

Personal iPad PDF reader with Apple Pencil ink, for one user (the owner). Never App Store.
Owner's bar: **Preview's speed and look, without Preview's page-losing habits, and writing that is crisp at any zoom.**

Authoritative docs, in order: `spec/SPEC.md` → `spec/WORK-PACKAGES.md` → `spec/notes/*.md` (design notes + findings logs) → `spec/SMOKE.md` (must pass on the iPad before any merge to `main`). **Full history of what worked and what didn't, process and technical: `spec/notes/LESSONS.md`.** If code and spec disagree, the spec wins; if you change behaviour, change the spec first.

## Where things are (2026-09-16)

- `main` = tag **`stable-drawing-v1`**. Owner: "crisp and beautiful, feels natural — 95 % of what bothered me is solved." **Do not regress the writing path.**
- Deploy to the iPad (one command; iPad awake on Wi-Fi):
  `xcodebuild -project PenPDF.xcodeproj -scheme PenPDF -destination 'id=8E516571-39A1-5391-B303-92B22DDC5FC3' -allowProvisioningUpdates -derivedDataPath build build && xcrun devicectl device install app --device 8E516571-39A1-5391-B303-92B22DDC5FC3 build/Build/Products/Debug-iphoneos/PenPDF.app && xcrun devicectl device process launch --device 8E516571-39A1-5391-B303-92B22DDC5FC3 com.georgebuhanov.penpdf`
  Then check it's alive: `xcrun devicectl device info processes --device 8E516571-… | grep -c PenPDF.app` (a crash on launch shows as 0).
- Simulator `F30083E9-7275-4D26-A8F9-7590500EA40F` exists but has no Pencil: use it only as a compile/launch check. **All real verification is on the iPad by the owner.**
- Bundle id `com.georgebuhanov.penpdf`, team `9F7BA86SV7`. Never edit `project.pbxproj` (synchronized folder — new files compile automatically).
- Parked branches: `fix/s3-stroke-only-canvas` (failed), `exp/s4-live-bitmap` (impossible), `exp/s5b-pinch-mirror` (nice-to-have, wrong maths — see notes).

## The ink architecture — and the mistakes not to repeat

**Root cause of every blur problem:** a `PKCanvasView` placed *inside* PDFKit's page/document view is magnified by PDFKit's zoom transform — a finished bitmap stretched like a photo. Apple DTS: no workaround. This affects the stroke *while it is being drawn*, so no post-hoc trick can fix it.

**What does NOT work (all tried on device — do not retry without a new decision):**
1. `contentScaleFactor` on the canvas or its subviews — PencilKit ignores it.
2. PencilKit's own `zoomScale` + a `1/z` counter-transform on an overlay canvas — fights UIScrollView internals, drifts off the page after repeated zooms.
3. Rendering settled strokes to a crisp bitmap and swapping layers at pen-down/up (S2/S3) — sharpens the past, but the live stroke is still magnified, and the swap shifts/blurs existing ink on every touch.
4. Re-rendering a bitmap while the pen is down (S4) — PencilKit does not expose the in-progress stroke until pen-up.

**What works (S5, on `main`): move the pen out from under the magnifier.**
```
PDFKit scroll view
├─ document view   ← PDFKit zooms this; pages live here
└─ ScreenCanvasView ← ONE PKCanvasView, sibling, never transformed: 1 canvas pt = 1 screen pt
```
- Ink is stored per page in **page space** (`DocumentStore`, sidecar `.drawing` files, origin top-left, y-down). `ScreenInkController` projects visible pages into scroll-content coordinates (`scale(s,s)` then translate to the page's top-left — **no Y flip**, only PDFKit's page space is y-up) and commits new strokes back by inverse transform, assigned to the page under the stroke's first point.
- The canvas's `contentOffset` is mirrored from the scroll view synchronously (KVO) → ink is glued to the page during scrolling with zero re-projection. During a pinch the ink is hidden and re-projected when the gesture ends (mirroring the live zoom is parked on `exp/s5b-pinch-mirror`).
- Tool widths are multiplied by the zoom → page-space widths like Preview.
- Because the canvas is inside the scroll view, finger gestures reach PDFKit's own pan/pinch as ancestors: **no touch-routing code**. (`event.allTouches` is nil during hit-testing for new touches — never decide pencil-vs-finger in `hitTest`.)
- Speed: the stroke path is PencilKit's unmodified low-latency pipeline; nothing of ours runs while the pen is down.

**PencilKit delegate-ordering rules (each one was a device bug):**
- Never assign `canvas.drawing` while the pen is down — it cancels the stroke in progress.
- `didEndUsingTool` can precede the drawing update; the **eraser commits asynchronously**. Never commit speculatively at pen-up; commit on `drawingDidChange` with the pen up (or at pen-up if a change already arrived mid-gesture). A "nothing changed" fallback may only resume syncing.
- Assigning `canvas.drawing` programmatically fires `drawingDidChange` — guard with a flag.
- After a commit, do not re-assign the canvas; it already shows the result.
- The canvas's `undoManager` returns nil; undo is explicit per page drawing.

## Other load-bearing decisions (see SPEC.md for the why)
`drawingPolicy = .pencilOnly` · content-hash document identity (never path) · restore position **before** observing page changes · `scrollsToTop = false` on every scroll view · resize handled as a settling window with saves suppressed · source PDF never modified · Preview's baked-in ink renders as a low-res bitmap (their appearance stream) — FR-30 plans to import it.

## How we work
- Spec first; owner tests on the iPad; findings go into the relevant `spec/notes/*.md` findings log **before** the fix.
- Delegated packages (Sonnet) get the ground-rules block from `WORK-PACKAGES.md`; the orchestrator reviews code, rebuilds, deploys. Agents have introduced subtle bugs before (a Y-flip, a hit-test guess) — read their geometry and touch code, don't trust the report.
- Use context7 for Apple API signatures and swift-lsp for navigation; don't dump whole files or boot simulators unnecessarily (`~/.claude/CLAUDE.md`).
- Commit as the owner (`-c user.name="George Buhanov" -c user.email="gbuhanov@gmail.com"`), with the Claude co-author trailer; experiments on branches; merge to `main` only after `spec/SMOKE.md` passes, then re-tag.

## Open items (owner picks)
FR-32 palm-safe navigation (pen-down auto-lock or two-finger pan; Lock is the interim answer) · FR-30 adopt Preview ink · FR-29 export with ink · FR-6 password PDFs · point-level restore at fit width · text selection/link taps (canvas takes them) · stroke-width parity with Preview ("one level thinner", accepted).
