# S3 — Stroke-only live canvas (device fix for pen-down bounce / blur / eraser ghost)

**Status:** in progress, branch `fix/s3-stroke-only-canvas`. Replaces the S2 mode-swap for settled ink.

## Owner-reported on iPad Pro 11" (2026-09-16)
1. On pen-down, existing ink **shifts 1–2 px** (down-right → up-left) and goes **soft/out of focus**; on pen-up it snaps back sharp and shifts back.
2. After erasing, the erased strokes **reappear briefly** before vanishing.
Writing latency itself is fine.

## Root cause
S2 swaps the *whole page's ink* between two layers at pen-down/up: crisp bitmap (idle) ↔ magnified live `PKCanvasView` (drawing). The two are not pixel-identical: the canvas raster is bitmap-magnified by PDFKit (soft) and lands on a different sub-pixel grid than a bitmap whose rect is `drawing.bounds ∓ 8pt` snapped at render scale. So every touch visibly re-renders everything already written. The eraser ghost is the stale bitmap being shown again between pen-up and the post-erase render.

## Design
**Invariant: settled ink never changes appearance at pen-down or pen-up. The crisp bitmap stays visible at all times; the live canvas only ever shows the stroke being drawn right now.**

- Per page the coordinator owns `fullDrawing: PKDrawing` (the truth; what the store persists; what the bitmap renders). The canvas's `drawing` is transient.
- **Inking tools (pen/marker/pencil etc.) — the common path:**
  - Idle: `canvas.drawing = PKDrawing()` (empty), canvas visible (no mask needed — empty canvas draws nothing), bitmap visible.
  - Pen-down: nothing changes on screen. PencilKit renders the in-progress stroke on the empty canvas above the bitmap.
  - `drawingDidChange` while pen down: no-op (don't merge mid-stroke).
  - Pen-up (`didEndUsingTool`) → wait for `drawingDidChange` (the stroke landing; same ordering rules as S2): `fullDrawing.append(canvas.drawing.strokes)`; register undo (see below); persist; render bitmap from `fullDrawing` **with the canvas still showing the new stroke**; when the bitmap is applied, `canvas.drawing = PKDrawing()`. The stroke goes from "live raster" to "crisp bitmap" in one frame with no gap and nothing else on the page changing.
- **Eraser / lasso — tools that need existing strokes in the canvas:**
  - On `didBeginUsingTool` with `canvas.tool is PKEraserTool || PKLassoTool`: `canvas.drawing = fullDrawing` and **hide the bitmap** (`inkImageView.isHidden = true`) *in the same run-loop turn, before the first touch renders*. This swap is visible (the soft/shift artefact) but only for eraser/lasso, which the owner uses far less than the pen; acceptable for now, noted as a possible later refinement (render the bitmap at the canvas's grid).
  - Pen-up → the change lands (`drawingDidChange`) → `fullDrawing = canvas.drawing`; render bitmap; on apply: `canvas.drawing = PKDrawing()`, show bitmap. **Never show the old bitmap in between** — the canvas keeps showing the (already-erased) drawing until the new bitmap is ready. This is what removes the ghost. If nothing changes (eraser on empty space): fallback after 250 ms → same procedure with the unchanged `fullDrawing` (cheap).
  - Tool detection: `canvas.tool` at `didBeginUsingTool`; also handle `PKToolPicker` changing tool mid-page: nothing to do until the next pen-down.
- **Undo / redo:** the Reader's `UndoManager` no longer gets PencilKit's automatic registrations in a useful form (the canvas is cleared after each stroke). Register explicitly: on every commit, `undoManager.registerUndo(withTarget: self) { $0.setFullDrawing(previous, page) }` with redo symmetric; `setFullDrawing` updates `fullDrawing`, persists, re-renders. Disable PencilKit's own registration by giving the canvas no undo manager path: override `undoManager` on `PageCanvasView` to return `nil`... **check**: `UIResponder.undoManager` is resolved via responder chain; overriding it on the canvas to `nil` stops PencilKit registering there. Verify on device that toolbar undo/redo round-trips a stroke and an erase.
- **Persistence:** `store.update(fullDrawing, forPage:)` on every commit; `pushLiveDrawingsToStore` pushes `fullDrawing` (plus any un-committed canvas strokes merged, for background/kill safety).
- **Recycling:** `willEndDisplaying` → commit anything in the canvas, drop.
- **Zoom re-render** unchanged (renders `fullDrawing`).
- `PageOverlayView.Mode` goes away or becomes `{ idle, erasing }`; the layer mask is no longer needed for the pen path (empty canvas is invisible). Keep `hitTest` (ink-off → nil).

## Acceptance (device)
1. Pen-down on a page with existing ink: **nothing already written changes** — no shift, no blur. Pen-up: the new stroke turns crisp in place with no jump.
2. Eraser: erased strokes never reappear. Lasso move works.
3. Undo/redo from the toolbar: undoes a stroke, an erase, a lasso move; redo restores.
4. Kill mid-stroke-session → relaunch → all committed strokes present.
5. Zoom cycles: unchanged from S2 (crisp, stable).
6. Latency unchanged (side-by-side with Notes).

## Result — FAILED on device 2026-09-16
Owner: eraser doesn't work; a new stroke gets connected to previous writing by a line (the cleared canvas / appended strokes path misbehaves); shift mostly fixed but the stroke under the pencil is extremely blurry while writing, then snaps sharp on lift — "the writing layer is crap". Branch kept for the record; NOT merged. Owner asked to compare against the pre-S2 baseline (`2236225`, plain PKCanvasView overlay).
