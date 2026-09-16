# S4 — Live bitmap: render the crisp layer on every stroke change (EXPERIMENT, branch `exp/s4-live-bitmap`)

Owner's idea (2026-09-16): S2's settled-ink bitmap "looks perfect" — so never show the PKCanvasView at all; re-render the bitmap continuously while the pen is down. Orchestrator's expectation: crisp, but bypasses PencilKit's predicted-touch Metal pipeline (CPU raster + texture upload per change, ≥ 1 frame behind the pen) — latency likely perceptible. Built anyway so the owner can feel the trade-off directly.

Mechanics: `PageOverlayView.liveBitmap` keeps the canvas masked in `.drawing` mode and the bitmap visible; `InkOverlayCoordinator.liveBitmapEnabled` renders `canvas.drawing` (settled + in-progress) on every `drawingDidChange` with the pen down, bounded to one render in flight per page (newest state rendered next; no queue). Pen-up/eraser/zoom/undo paths unchanged from S2.

Acceptance is subjective: owner compares writing feel and look at their real zoom against S2 (`main`) and the baseline (`2236225`).
