# S5 — Screen-scale canvas as a sibling above PDFView (EXPERIMENT, branch `exp/s5-screen-canvas`)

**Goal:** Preview's live-writing quality — thick, sharp, PencilKit-rendered strokes at ANY zoom, zero added latency — by taking the `PKCanvasView` OUT of PDFKit's scaled view tree. Root cause of every previous failure (S1–S4): a canvas *inside* PDFKit's page overlay is bitmap-magnified by an ancestor transform. Apple DTS: no workaround. So the canvas must not be a descendant of PDFView.

## Architecture
```
ReaderViewController.view (ResponderView)
├─ pdfView : PDFView                 renders pages; scrolls/zooms exactly as today (all invariants kept)
└─ screenCanvas : ScreenCanvasView   ONE PKCanvasView, frame == pdfView.frame, never transformed,
                                     never scrolled by the user (isScrollEnabled = false, zoom 1)
```
- `screenCanvas` sits above `pdfView` at 1:1 screen pixels. PencilKit renders at native resolution ⇒ crisp at any PDF zoom, with its full low-latency pipeline (predicted touches, Metal) because we do not touch its rendering at all.
- **Stroke width follows zoom** (Preview behaviour): the tool's width is in canvas points = screen points, so at 3× PDF zoom a 3-pt pen looks 3 pt on screen and ~1 pt on the page — exactly what Preview does. Nothing to implement.
- `PDFPageOverlayViewProvider` is no longer used for ink. `PageOverlayView`/`PageCanvasView`/bitmap pipeline are retired on this branch.

## Coordinate model
Per page `p` the sidecar stores a `PKDrawing` in **page space** (unrotated PDF points, origin top-left of the page as PDFKit presents it — same as the existing files, so persisted ink stays compatible).
- `pageToScreen(p) : CGAffineTransform` = PDFKit: `pdfView.convert(CGPoint, from: page)` gives view coordinates for page points; composing scale `s = pdfView.scaleFactor` and the page's origin in view coordinates yields an affine transform (no rotation in v1; rotated pages: apply `page.rotation` — verify with the mixed-rotation test PDF).
- **Display:** `screenCanvas.drawing = union over visible pages p of storeDrawing(p).transformed(using: pageToScreen(p))`. `PKDrawing.transformed(using:)` and `PKStroke.transformed` are public API (iOS 14+). Recomputed on every `.PDFViewScaleChanged`, `.PDFViewPageChanged`, and scroll (`UIScrollView` KVO on `contentOffset` of PDFKit's scroll view, found by the existing walk) — coalesced to one update per display frame via `CADisplayLink` or `setNeedsLayout`-style flag.
- **Commit (pen-up, `drawingDidChange` with pen up):** new strokes = `screenCanvas.drawing.strokes` beyond the displayed set (track by count, or diff against the last-set drawing). For each new stroke: page = the page under the stroke's first point (`pdfView.page(for: point, nearest: true)`); `stroke.transformed(using: pageToScreen(page).inverted())` → append to `storeDrawing(page)`; persist; register undo on the page drawing (explicit, like S3's model — PencilKit's own undo must be detached: `ScreenCanvasView.undoManager` returns nil). Then re-set `screenCanvas.drawing` from the store (so the canvas never accumulates its own state — it is a *view* of the store).
- **Eraser / lasso:** they operate on the *displayed* drawing (screen space). On pen-up: diff displayed vs canvas → for each visible page, `storeDrawing(p) = canvas strokes that belong to p, transformed back` (strokes are identified by index order; a stroke that moved pages via lasso follows its first point). Simplest correct rule: rebuild every visible page's drawing from the canvas on eraser/lasso commit.
- **Palm / touches:** `drawingPolicy = .pencilOnly` as always. Finger touches must reach PDFView underneath: `ScreenCanvasView.hitTest` returns nil for `.direct` touches (`event?.allTouches?.first?.type != .pencil`) → they fall through to PDFView; Pencil touches go to the canvas. `isInMarkupMode` on PDFView no longer needed (set false).
- **Lock:** unchanged (walk over pdfView only).
- **Scrolling while the pen is down** (palm drift, or two-finger scroll mid-stroke): the displayed drawing must not move under the stroke in progress. Rule: while `didBeginUsingTool…didEndUsingTool`, suppress display re-sync; apply the pending sync at pen-up *after* commit. PDFKit may still pan under a resting palm — FR-32 (two-finger pan) addresses that separately and should be included in this spike since the canvas now sits above PDFView.
- **Sync latency during pinch:** the canvas is re-rendered from the transformed drawing once per frame; a 1-frame lag between page and ink during a fast pinch is acceptable; drift after the gesture is not (assert: after any zoom/scroll settles, ink matches the page exactly — the transform is recomputed from PDFKit's current state, so this is by construction).
- **Performance:** `drawing.transformed(using:)` per frame for all visible pages. Acceptable for hundreds of strokes; if a page with thousands of strokes stutters during scroll, cache per-page transformed drawings keyed by (page, scale) and only re-offset (translation is cheap). Measure on device.

## What must NOT change
Store/sidecar format, identity, position persistence, lock walk, toolbar, palette (anchor unchanged), FR-10 invariants, `drawingPolicy`.

## Acceptance (device)
1. Write at the owner's usual zoom: stroke is **sharp while writing** and after; thickness behaves like Preview; feel indistinguishable from Notes.
2. Zoom in/out repeatedly: ink stays exactly on the page content after every gesture (≤ 1-frame lag during).
3. Scroll fast through pages with ink: ink follows, no tearing at page boundaries, no ink from page N drawn on page N+1.
4. Eraser (pixel/object), lasso move (within a page), undo/redo: work; persist across relaunch.
5. Draw across two visible pages in one stroke: acceptable to assign the whole stroke to the page of its first point (document it).
6. Rotated-page PDF: ink aligned.
7. Palm: single-finger never pans (FR-32); Lock still total.
8. Kill/relaunch: all ink present at the right place.
