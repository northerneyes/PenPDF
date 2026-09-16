import PDFKit
import PencilKit
import UIKit

/// Bridges PDFKit's page overlay mechanism to PencilKit (SPEC §3.4, §5.4).
///
/// One `PageOverlayView` exists per page PDFKit is currently displaying,
/// wrapping a `PageCanvasView` (S2 Option B, `spec/notes/S2-option-b-crisp-ink.md`
/// — replaces spike S1, which drove `PKCanvasView`'s own zoom and is gone;
/// see `deferred.md` for why S1 failed). PDFKit asks for an overlay as a page
/// scrolls on screen and tells us when it scrolls off; in between, strokes
/// flow through `PKCanvasViewDelegate` into `DocumentStore`, and settled
/// strokes are periodically re-rendered into a crisp bitmap shown by the
/// overlay's `inkImageView` while the canvas itself sits invisible (but live)
/// underneath. PDFKit owns an overlay's `frame` entirely (SPEC §5.4 "Overlay
/// for page") — never set it, or the canvas's.
final class InkOverlayCoordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {

    private let document: PDFDocument
    private let store: DocumentStore
    private let toolPicker: PKToolPicker

    private var liveOverlays: [Int: PageOverlayView] = [:]

    /// The `PDFView` we're providing overlays for, captured from whichever
    /// PDFKit callback last handed us one. `PKCanvasViewDelegate` callbacks
    /// don't receive it, but still need it to probe on-screen magnification
    /// (`render`'s `pdfView` parameter) — there is exactly one `PDFView` per
    /// Reader, so caching it here is safe.
    private weak var currentPDFView: PDFView?

    /// FR-18a: ON (the default, every launch, never persisted) makes the
    /// Pencil draw, like Apple Notes. OFF makes the Pencil behave exactly
    /// like a finger — Preview's markup button does the same thing — which
    /// in the simulator (mouse == finger, `anyInput`) is the only way to
    /// scroll a page without drawing on it.
    private(set) var isInkEnabled = true

    // MARK: - Rendering (S2 Option B)

    /// Off-main queue for `PKDrawing.image(from:scale:)`, which can be slow
    /// at high render scales — never block the main thread with it (design
    /// note "Off-main: render on a serial utility queue").
    private let renderQueue = DispatchQueue(label: "penpdf.ink.render", qos: .userInitiated)

    /// Bumped every time a page's render is (re)issued or the page's overlay
    /// goes away; a completed render only applies if its generation still
    /// matches, so a stale/cancelled result never clobbers a newer one.
    private var renderGeneration: [Int: Int] = [:]

    /// The bitmap scale (`UIScreen.main.scale × z`, capped) used for a page's
    /// most recent render, so `rerenderForZoom` can tell whether the zoom has
    /// moved enough to be worth a re-render.
    private var lastRenderScale: [Int: CGFloat] = [:]

    /// Bounds the PencilKit-native render scale independent of how far PDFKit
    /// itself is zoomed — bounds the rendered bitmap's memory (SPEC NFR-3).
    private static let maxZoomForRender: CGFloat = 4

    init(document: PDFDocument, store: DocumentStore, toolPicker: PKToolPicker) {
        self.document = document
        self.store = store
        self.toolPicker = toolPicker
        super.init()
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        currentPDFView = view
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }

        if let existing = liveOverlays[index] {
            return existing
        }

        let canvas = PageCanvasView()
        // SPEC §5.6, exact. The simulator has no Apple Pencil, so smoke
        // testing there needs mouse input; never relax this on device.
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.scrollsToTop = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.pageIndex = index
        canvas.delegate = self
        let drawing = store.drawing(forPage: index)
        canvas.drawing = drawing
        canvas.tool = toolPicker.selectedTool
        // FR-18a: a canvas created while ink is toggled off must come up
        // inert too, so it doesn't grab pages scrolled in after the toggle.
        canvas.isUserInteractionEnabled = isInkEnabled
        toolPicker.addObserver(canvas)

        let overlay = PageOverlayView(canvas: canvas)
        overlay.setMode(.idle)
        liveOverlays[index] = overlay

        // Design note "Re-render triggers: canvas creation (from store)".
        // `overlay.superview` isn't necessarily set yet at this point, so the
        // magnification probe inside `render` may fall back to 1×; the
        // follow-up `willDisplayOverlayView` call re-renders at the true
        // scale once PDFKit has placed the overlay.
        render(pageIndex: index, drawing: drawing, overlay: overlay, pdfView: view, then: .idle)

        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        currentPDFView = pdfView
        // A recycled overlay may come back at a different on-screen zoom than
        // when it was last rendered (design note) — catch it here rather
        // than waiting for the next `.PDFViewScaleChanged`.
        rerenderForZoom(in: pdfView)
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageOverlayView else { return }
        let canvas = overlay.canvas
        store.update(canvas.drawing, forPage: canvas.pageIndex)
        toolPicker.removeObserver(canvas)
        liveOverlays.removeValue(forKey: canvas.pageIndex)
        // Cancel/ignore any render still in flight for this page — its
        // result would otherwise apply to an overlay nothing displays
        // anymore (design note "cancel/ignore pending renders").
        renderGeneration[canvas.pageIndex, default: 0] += 1
        pagesWithPenDown.remove(canvas.pageIndex)
        lastRenderScale.removeValue(forKey: canvas.pageIndex)
    }

    // MARK: - PKCanvasViewDelegate

    /// Pages whose canvas currently has the pen down. PencilKit's delegate
    /// order on pen-up is not guaranteed: `didEndUsingTool` can arrive
    /// BEFORE the finished stroke is committed to `canvas.drawing` (and
    /// before `drawingDidChange`). Rendering synchronously in `didEndUsingTool`
    /// therefore produced an image without the new stroke, and the follow-up
    /// `drawingDidChange` was ignored because the overlay was still in
    /// `.drawing` mode — the stroke stayed hidden until the next pen-up
    /// (owner-reported, 2026-09-16). Tracking pen state explicitly, deferring
    /// the pen-up render one run-loop turn, and re-rendering on any drawing
    /// change while the pen is up closes both orderings.
    private var pagesWithPenDown: Set<Int> = []

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView,
              let overlay = liveOverlays[canvas.pageIndex]
        else { return }
        pagesWithPenDown.insert(canvas.pageIndex)
        overlay.setMode(.drawing)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView else { return }
        let pageIndex = canvas.pageIndex
        pagesWithPenDown.remove(pageIndex)
        // Next turn: by then PencilKit has committed the stroke. `drawing` is
        // read inside the block on purpose. Generation counting in `render`
        // makes any overlap with `drawingDidChange` harmless — latest wins.
        DispatchQueue.main.async { [weak self, weak canvas] in
            guard let self, let canvas,
                  let overlay = self.liveOverlays[pageIndex], overlay.canvas === canvas,
                  let pdfView = self.currentPDFView
            else { return }
            self.render(pageIndex: pageIndex, drawing: canvas.drawing, overlay: overlay, pdfView: pdfView, then: .idle)
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView else { return }
        store.update(canvas.drawing, forPage: canvas.pageIndex)

        // Any change while the pen is up — the just-finished stroke landing
        // late, undo/redo, lasso move, object-eraser tap — must reach the
        // image layer. While the pen is down the live canvas is showing, so
        // rendering would be wasted; pen-up handles it.
        guard !pagesWithPenDown.contains(canvas.pageIndex),
              let overlay = liveOverlays[canvas.pageIndex],
              let pdfView = currentPDFView
        else { return }
        render(pageIndex: canvas.pageIndex, drawing: canvas.drawing, overlay: overlay, pdfView: pdfView, then: .idle)
    }

    // MARK: - Rendering (S2 Option B, design note "Rendering the image")

    /// Renders `drawing`'s settled strokes into `overlay.inkImageView` at a
    /// bitmap scale matched to the overlay's current on-screen magnification,
    /// so PDFKit's ancestor transform samples it 1:1 instead of bitmap-
    /// magnifying PencilKit's own (lower-resolution) rendering.
    private func render(
        pageIndex: Int,
        drawing: PKDrawing,
        overlay: PageOverlayView,
        pdfView: PDFView,
        then mode: PageOverlayView.Mode?
    ) {
        let z = magnification(of: overlay, in: pdfView)
        let renderScale = min(UIScreen.main.scale * z, UIScreen.main.scale * Self.maxZoomForRender)

        let rect = drawing.bounds.insetBy(dx: -8, dy: -8).intersection(overlay.bounds)
        guard !drawing.strokes.isEmpty, !rect.isNull, !rect.isEmpty else {
            overlay.apply(rendered: nil)
            if let mode { overlay.setMode(mode) }
            return
        }

        renderGeneration[pageIndex, default: 0] += 1
        let generation = renderGeneration[pageIndex]!

        renderQueue.async { [weak self, weak overlay] in
            let image = drawing.image(from: rect, scale: renderScale)
            DispatchQueue.main.async {
                guard let self, let overlay,
                      self.liveOverlays[pageIndex] === overlay,
                      self.renderGeneration[pageIndex] == generation
                else { return }
                overlay.apply(rendered: RenderedInk(image: image, rect: rect))
                self.lastRenderScale[pageIndex] = renderScale
                if let mode { overlay.setMode(mode) }
            }
        }
    }

    /// Re-renders any idle page whose ink bitmap no longer matches the
    /// current on-screen zoom by more than 1% — called after the Reader's
    /// 150 ms zoom-settle debounce, and directly (cheap when nothing's
    /// changed) from layout passes and overlay recycling.
    func rerenderForZoom(in pdfView: PDFView) {
        currentPDFView = pdfView
        guard let referenceOverlay = liveOverlays.values.first else { return }
        let z = magnification(of: referenceOverlay, in: pdfView)
        let renderScale = min(UIScreen.main.scale * z, UIScreen.main.scale * Self.maxZoomForRender)

        for (index, overlay) in liveOverlays {
            // A page mid-stroke re-renders on pen-up instead (design note).
            guard overlay.mode == .idle else { continue }
            let previous = lastRenderScale[index] ?? 0
            guard previous <= 0 || abs(renderScale - previous) / previous > 0.01 else { continue }
            render(pageIndex: index, drawing: overlay.canvas.drawing, overlay: overlay, pdfView: pdfView, then: .idle)
        }
    }

    /// The on-screen magnification PDFKit is applying to this overlay's
    /// superview — same probe as spike S1, but now only ever used to pick a
    /// bitmap render scale, never to transform a live view, so it cannot
    /// introduce drift. Falls back to 1 if the overlay isn't in the
    /// hierarchy yet (design note).
    private func magnification(of overlay: PageOverlayView, in pdfView: PDFView) -> CGFloat {
        guard let superview = overlay.superview else { return 1 }
        let probe = superview.convert(CGRect(x: 0, y: 0, width: 100, height: 100), to: pdfView)
        let z = probe.width / 100
        guard z.isFinite, z > 0 else { return 1 }
        return z
    }

    // MARK: - Flush (SPEC §5.4 "Flush everything")

    /// Pushes every currently-live overlay's drawing into the store. Called
    /// by the Reader before it saves position and flushes the store to disk
    /// — `willEndDisplayingOverlayView` only fires for pages that actually
    /// scroll off, not for the ones still on screen when the app backgrounds.
    func pushLiveDrawingsToStore() {
        for (index, overlay) in liveOverlays {
            store.update(overlay.canvas.drawing, forPage: index)
        }
    }

    // MARK: - Tool palette (FR-18)

    func togglePalette(for responder: UIResponder) {
        toolPicker.setVisible(!toolPicker.isVisible, forFirstResponder: responder)
    }

    func setPaletteVisible(_ visible: Bool, for responder: UIResponder) {
        toolPicker.setVisible(visible, forFirstResponder: responder)
    }

    // MARK: - Ink on/off (FR-18a)

    /// Flips the ink flag, disables/enables every live canvas so the Pencil
    /// starts panning/scrolling like a finger instead of drawing (or draws
    /// again), and follows with the palette's visibility. `PageOverlayView.hitTest`
    /// reads `canvas.isUserInteractionEnabled` directly, so nothing else here
    /// needs to change for the toggle to take effect.
    func setInkEnabled(_ enabled: Bool, for responder: UIResponder) {
        isInkEnabled = enabled
        for overlay in liveOverlays.values {
            overlay.canvas.isUserInteractionEnabled = enabled
        }
        toolPicker.setVisible(enabled, forFirstResponder: responder)
    }
}
