# S2 — Option B: crisp ink via a settled-strokes image layer (EXPERIMENT, branch `exp/option-b-crisp-ink`)

**Status:** experimental. Nothing here is accepted into SPEC.md until the owner passes it on the simulator and the iPad. `main` keeps the baseline overlay (`PKCanvasView` only).

## Why (recap)
`PKCanvasView` under a PDFKit ancestor transform is bitmap-magnified; Apple DTS: no workaround (deferred.md). A plain `CALayer`/`UIImageView` *does* honour its bitmap's `contentsScale`, so a bitmap rendered at `screenScale × z` is sampled 1:1 after a `z×` ancestor transform — crisp. Preview commits strokes to PDF annotations for the same reason; we commit them to an image instead so the file is never touched and PencilKit's look is preserved (`PKDrawing.image(from:scale:)` is PencilKit rendering).

## Design (per page overlay)
```
PageOverlayView (UIView, returned to PDFKit; PDFKit owns its frame — unchanged rule)
├─ inkImageView : UIImageView   settled strokes, crisp; isUserInteractionEnabled = false
└─ canvas       : PageCanvasView (unchanged config; holds the FULL drawing at all times)
```
- **Idle:** `canvas.alpha = 0`, `inkImageView.isHidden = false`. The canvas still holds the full drawing and still receives Pencil touches (see hit-test).
- **Drawing:** on `canvasViewDidBeginUsingTool` → `canvas.alpha = 1`, `inkImageView.isHidden = true` (live stroke and the rest of the page's ink render via PencilKit; soft at high zoom only while the pen is down).
- **Pen up:** on `canvasViewDidEndUsingTool` → re-render the image from `canvas.drawing`, then (on completion) `inkImageView.isHidden = false`, `canvas.alpha = 0`. No flash: swap only after the new image is ready.
- **Eraser / lasso / undo / redo** work unchanged — the canvas always has the full drawing. Any `canvasViewDrawingDidChange` while idle (undo/redo from the toolbar) → re-render.
- **Hit-testing:** `PageOverlayView.hitTest` returns `canvas` for points inside bounds when `canvas.isUserInteractionEnabled` (ink on) — this bypasses UIKit's `alpha < 0.01` rejection for the invisible canvas. When ink is off (FR-18a debug) return `nil` so touches fall through to PDFView. `drawingPolicy = .pencilOnly` still means fingers never draw; a finger touch that reaches the canvas is ignored by PencilKit and PDFView's ancestor pan still recognises it, exactly as today.
- **Lock (§5.7):** the walk skips `PKCanvasView` subtrees; `PageOverlayView` has no recognisers. No change.

## Rendering the image
- `renderScale = min(UIScreen.main.scale × z, maxScale)` where `z` = on-screen magnification of the overlay (probe: `overlay.superview.convert(100×100, to: pdfView).width / 100`, same as S1) and `maxScale` bounds memory (start with `UIScreen.main.scale × 4`).
- Render only the ink's extent: `rect = drawing.bounds.insetBy(-8).intersection(overlay.bounds)`; `image = drawing.image(from: rect, scale: renderScale)`; `inkImageView.frame = rect`; `inkImageView.image = image`. Empty drawing → `image = nil`, hidden.
- Off-main: render on a serial utility queue; tag each request with a generation counter per page; drop stale results; apply on main.
- **Re-render triggers:** canvas creation (from store), pen up, drawing change while idle, `.PDFViewScaleChanged` **settled** (150 ms quiet, same timer as S1 — but here the timer only re-renders a bitmap; it never touches geometry, so it cannot drift), overlay `willDisplay` if scale changed since last render.
- Memory note: extent-based rendering keeps cost proportional to inked area; a fully-inked Letter page at 4× on a 2× screen is ~124 MB — the cap exists for that case; lower `maxScale` if the simulator/iPad shows memory pressure.

## What must NOT change
`PageCanvasView` config (§5.6), `InkOverlayCoordinator` store/tool-picker flow, `DocumentStore`, sidecar format, `drawingPolicy`, no frame/transform on the canvas or overlay (PDFKit owns them; children use autoresizing to fill).

## Acceptance (simulator, owner)
1. Idle at fit width: ink looks identical to `main`.
2. Zoom ~3×: after the pinch settles (≤ ~0.2 s) ink is **sharp**; during the pinch it may be soft but must stay aligned and never drift — repeat 10 big zoom in/out cycles.
3. Draw at 3×: live stroke appears under the cursor immediately; on pen-up the page snaps to crisp with no visible jump/offset and no double-image ghosting.
4. Eraser (pixel + object), lasso-move, undo, redo all still work and the image updates.
5. Pages scrolled away and back show correct ink; kill/relaunch same.
6. Lock and debug ink-off behave as on `main`.
7. Memory: after 10 minutes of drawing/zooming on 5 pages, Xcode/`simctl` memory for the process stays < 400 MB.
Failure on 2–3 → note findings here, do not iterate on `main`-affecting code; the branch just stays a branch.

## Findings log
- 2026-09-16 · Owner: zoom crispness "looks perfect", but **drawing was dead**. Cause: idle canvas hidden with `alpha = 0` + container `hitTest` returning the canvas itself. PencilKit's stroke recognizer sits on an internal *subview* of `PKCanvasView`; UIKit delivers a touch to the hit-test result and its ancestors' recognisers, never a descendant's — so the canvas got the touch and nobody drew. Fix: hide the idle canvas with a zero-size `layer.mask` (invisible, but hit-testing ignores masks) and let `hitTest` descend normally; only the ink-off case returns nil. Design section above amended by this note.
- 2026-09-16 · Owner: crispness, position, writing feel all "perfect — same quality as Preview". Bug: a stroke only appeared after the *next* stroke. Cause: `canvasViewDidEndUsingTool` fires before PencilKit commits the stroke to `drawing`; the synchronous pen-up render missed it and the later `drawingDidChange` was skipped because the mode was still `.drawing`. Fix: explicit pen-down set, pen-up render deferred one run-loop turn, `drawingDidChange` re-renders whenever the pen is up.
