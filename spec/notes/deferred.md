# Deferred / P1 follow-ups

- 2026-09-15 · WP3 · `lastPoint` is never written on the simulator: `PDFView.currentDestination.point` fails the crop-box sanity check and is dropped (by design). Page-level restore (P0) works. P1: investigate the coordinate space PDFKit returns in continuous mode (may be view-space, not page-space) and restore point-in-page. Not blocking.
- 2026-09-15 · WP2 · `ReaderViewController.swift` is ~305 lines vs the 300-line guideline; WP6 may split position/ink hooks into extensions. Not blocking.
- 2026-09-15 · WP5 · `ReaderViewController.swift` is ~430 lines after lock/title/transition additions. WP6: split into `ReaderViewController+Position.swift`, `+Ink.swift`, `+Lock.swift` extensions (behaviour-neutral refactor only).
- 2026-09-15 · WP5 · Title thumbnail is nearly invisible for mostly-white first pages. WP6 may add a 0.5-pt hairline border (`separator` colour) around the 22×22 image so it reads as a document icon.
- 2026-09-15 · WP5c · After window resizes `meta.json` recorded `lastZoomRelativeToFit: 0.82` (page index correct). With `autoScales = true` PDFKit re-fits on every layout, so restoring a relative zoom fights it and can land at 82 % width. WP6 decision: only restore zoom when > 1.0 (user deliberately zoomed in); otherwise let autoScales fit. Keep writing the field.
- 2026-09-15 · WP4 · **Ink is blurry when zoomed in** (owner, simulator) — alignment and size are correct. Cause: PDFKit scales the overlay via a transform, so the PKCanvasView's raster is bitmap-magnified rather than re-rendered. WP6 experiment: on `.PDFViewScaleChanged` and on canvas creation set `contentScaleFactor` (and recursively on the canvas's subviews) to `screenScale * max(1, scaleFactor / scaleFactorForSizeToFit)`, capped (e.g. ≤ 4× screen scale) to bound GPU memory. If ineffective, revert and re-test on device (Retina + real zoom) before considering alternatives. Never replace PencilKit rendering.
- 2026-09-15 · WP4 · Delete-when-empty verified: object-eraser cleanup removed `page-000002.drawing`. Pixel eraser leaves invisible fragments (expected PencilKit behaviour) — not a bug.

## WP6 done (2026-09-15)

Resolved:
- **Ink crispness experiment** (WP4 deferral): `InkOverlayCoordinator.updateContentScale(for:)` now
  bumps `contentScaleFactor`/`layer.contentsScale` on every live canvas (recursively into
  PencilKit's own subviews) to `min(screenScale * zoom, screenScale * 4)`, called from canvas
  creation, once after `pdfView.document` is set, and on every `.PDFViewScaleChanged` (unconditionally,
  not gated by the resize-pin window). Guarded against `scaleFactorForSizeToFit == 0` via
  `max(scaleFactorForSizeToFit, 0.0001)`. **Not verified visually** — this needs the owner's eyes on
  a real device at real zoom; if it does not visibly help, revert per the original deferral note and
  do not look for another approach (never replace PencilKit's own rendering).
- **"0.82" zoom-restore fight with `autoScales`**: `applyRestoredPosition()` now only restores
  `lastZoomRelativeToFit` when it is finite **and > 1.0** (i.e. the owner deliberately zoomed in);
  otherwise `autoScales` is left to fit width on its own. `savePosition()` still always writes the
  field, unchanged. Verified in the simulator: relaunching with a saved zoom of 1.83 restored that
  zoom (screenshot `build/wp6.png`, 4/12, zoomed).
- **Title thumbnail invisible on white pages**: `ReaderTitleView`'s 22×22 thumbnail now has a
  0.5pt `UIColor.separator` hairline border, refreshed via `registerForTraitChanges` on
  `UITraitUserInterfaceStyle` (not the deprecated `traitCollectionDidChange`, since deployment
  target is exactly iOS 17.0) so it stays correct across light/dark. Verified visible in
  `build/wp6.png`.
- **`ReaderViewController.swift` size**: split into `ReaderViewController+Position.swift` (130
  lines: restore/save/flush/sanitizedPoint/zoomRange/page-change observation),
  `+Resize.swift` (38 lines: `applyResizePin`/`scheduleResizeWindowEnd`), `+Lock.swift` (26 lines:
  `applyLockState`), and `+Ink.swift` (25 lines: the `#if DEBUG` ink toggle). Purely mechanical —
  no statement reordering, no renames, all WHY comments moved with their code. The main file is
  351 lines (target was ≤260; see the note in the WP6 report — the exact §5.5 `viewDidLoad`
  configuration plus `viewWillTransition`, which the WP6 brief itself keeps on the main file as a
  UIKit override, account for the overage, and no comment was cut to force the number down).

Still open (unchanged from before WP6, P1/P2, device-only):
- `lastPoint` coordinate-space investigation (WP3 note above) — not blocking.
- FR-6 password prompt, pencil-double-tap-to-lock, P2 flattened export via share sheet (see
  `WORK-PACKAGES.md` "P1 follow-ups").
- Full `TEST-CHECKLIST.md` pass with the owner on a real iPad with a real Apple Pencil — required
  by SPEC §9 before calling the MVP "done"; everything WP6 touched was only checked on the
  Simulator (`F30083E9-7275-4D26-A8F9-7590500EA40F`).
- The ink-crispness experiment's actual visual effect (see above) — Simulator has no real Retina
  Pencil zoom to judge it by.

## 2026-09-15 · Crisp ink at zoom — experiment A failed, spike S1 started
- Owner verdict on WP6 item A (`contentScaleFactor` propagation): **still blurry**. S1 removes it.
- Diagnosis: PDFKit magnifies the overlay with an ancestor transform; PencilKit's renderer draws at `zoomScale`-resolution, not at external contents-scale hints. Bitmap magnification ⇒ blur.
- S1 approach (PencilKit's native zoom, as Notes does): for each live canvas compute the on-screen magnification `z` of its superview (`superview.convert(100×100 rect, to: pdfView).width / 100`), then `canvas.minimumZoomScale = canvas.maximumZoomScale = canvas.zoomScale = z`, `canvas.transform = scale(1/z)`. Because `frame` under a transform is derived, PDFKit's own `frame = pageRect` assignments yield `bounds = pageRect × z` automatically — compatible. Re-apply on `.PDFViewScaleChanged`, `willDisplayOverlayView`, creation. Cap `z` at 4 (drawable memory). Behind `InkOverlayCoordinator.crispZoomEnabled` so a single flag reverts to spec-baseline geometry.
- This is the ONE sanctioned exception to SPEC §5.4 "do not set frame/transform". If the owner still sees blur or any misalignment, set the flag false and stop; no third approach without a new decision.
- 2026-09-15 · S1 follow-up (orchestrator): the spike's first version set `zoomScale`+`transform` but left `bounds` at page size, so the canvas covered only the top-left 1/z of the page (would clip strokes outside it; the agent's test stroke sat in that corner). Fixed by re-assigning PDFKit's on-screen `frame` after the transform (bounds ⇒ pageRect × z; verified in the CrispZoom log: frame 612×792, bounds 823×1065 at z = 1.345). Owner to judge sharpness + confirm no clipping on pages with ink spread across the page.
- 2026-09-15 · **S1 FAILED on owner test — flag off.** Crispness itself worked, but (1) ink visibly readjusted during pinch even with a 150 ms settle timer, and (2) after several large zoom-in/out cycles the ink drifted off the page entirely. Root cause not established (suspects: `UIScrollView.zoomScale`/`contentOffset` interplay inside `PKCanvasView` accumulating with repeated `frame` re-assignment under a transform; PDFKit re-framing mid-gesture). `crispZoomEnabled = false` restores spec-baseline geometry; code kept for a future spike **only with a new decision from the owner**. Next candidate, if ever: judge on device first — Retina + real Pencil zoom levels may make the blur acceptable; if not, a spike that measures PDFKit's overlay geometry per frame before touching anything.
- 2026-09-15 · Research on crisp ink at zoom (Apple Developer Forums): Apple DTS on thread 793494 — "PKCanvasView is a subclass of UIScrollView and the scaling behavior is simply how the UIScrollView works. There's no workaround for this behavior" → file an enhancement request. Thread 757202: `PKCanvasView` ignores `contentScaleFactor` updates (our experiment A, confirmed dead). Thread 792941: same `contentScaleFactor` + reassign-drawing hack, unresolved. Conclusion: no supported fix while PKCanvasView is magnified by an ancestor. Only architecturally different route left: render `PKDrawing.image(from:scale:)` into a plain image layer at the current zoom for display, and use the live `PKCanvasView` only while a stroke is in progress (hybrid). Significant complexity; decide on device only.
