import PDFKit
import PencilKit
import UIKit

/// Bridges PDFKit's page overlay mechanism to PencilKit (SPEC §3.4, §5.4).
///
/// One `PageOverlayView` exists per page PDFKit is currently displaying,
/// wrapping a `PageCanvasView` (S3, `spec/notes/S3-stroke-only-canvas.md` —
/// replaces S2's idle/drawing bitmap-swap, which visibly re-rendered a page's
/// already-settled ink on every pen-down/up; see that note's root cause, and
/// `spec/notes/S2-option-b-crisp-ink.md` for the crisp-bitmap-via-image-layer
/// idea this keeps). PDFKit asks for an overlay as a page scrolls on screen
/// and tells us when it scrolls off; in between, strokes flow through
/// `PKCanvasViewDelegate` into `fullDrawings` (the truth for a page) and
/// `DocumentStore`, and are periodically re-rendered into a crisp bitmap
/// shown by the overlay's `inkImageView`. Unlike S2, the live canvas does NOT
/// hold the full drawing at all times — see `ToolKind` below. PDFKit owns an
/// overlay's `frame` entirely (SPEC §5.4 "Overlay for page") — never set it,
/// or the canvas's.
final class InkOverlayCoordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {

    private let document: PDFDocument
    private let store: DocumentStore
    private let toolPicker: PKToolPicker

    private var liveOverlays: [Int: PageOverlayView] = [:]

    /// S3: per-page truth. What the store persists and what the bitmap
    /// renders from — never the canvas's own `drawing`, which is transient
    /// (design note "Per page the coordinator owns `fullDrawing`").
    private var fullDrawings: [Int: PKDrawing] = [:]

    /// S3 (`spec/notes/S3-stroke-only-canvas.md` "Undo / redo"): the Reader's
    /// single shared `UndoManager`, handed in once the Reader has created
    /// both itself and `ink` (see `ReaderViewController.init`). PencilKit's
    /// own registration is disabled per-canvas (`PageCanvasView.undoManager`
    /// returns `nil`); this is where the coordinator registers the real
    /// (full-drawing) undo/redo steps instead.
    weak var undoManager: UndoManager?

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

    // MARK: - Rendering (bitmap trick from S2, scale math unchanged)

    /// Off-main queue for `PKDrawing.image(from:scale:)`, which can be slow
    /// at high render scales — never block the main thread with it.
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
        // S3: the canvas starts (and, between gestures, stays) empty —
        // `fullDrawings[index]` is the truth and what the bitmap renders
        // (design note "Idle"). An empty canvas draws nothing, so it needs no
        // hiding.
        canvas.drawing = PKDrawing()
        canvas.tool = toolPicker.selectedTool
        // FR-18a: a canvas created while ink is toggled off must come up
        // inert too, so it doesn't grab pages scrolled in after the toggle.
        canvas.isUserInteractionEnabled = isInkEnabled
        toolPicker.addObserver(canvas)

        let fullDrawing = store.drawing(forPage: index)
        fullDrawings[index] = fullDrawing

        let overlay = PageOverlayView(canvas: canvas)
        liveOverlays[index] = overlay

        // Re-render triggers (S2 design note, still true under S3): canvas
        // creation (from store). `overlay.superview` isn't necessarily set
        // yet at this point, so the magnification probe inside `render` may
        // fall back to 1×; the follow-up `willDisplayOverlayView` call
        // re-renders at the true scale once PDFKit has placed the overlay.
        render(pageIndex: index, drawing: fullDrawing, overlay: overlay, pdfView: view)

        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        currentPDFView = pdfView
        // A recycled overlay may come back at a different on-screen zoom than
        // when it was last rendered — catch it here rather than waiting for
        // the next `.PDFViewScaleChanged`.
        rerenderForZoom(in: pdfView)
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageOverlayView else { return }
        let pageIndex = overlay.canvas.pageIndex
        // S3 (design note "Recycling"): commit anything the canvas is still
        // holding — an in-progress stroke, or a live eraser/lasso edit — so
        // scrolling a page off mid-gesture never loses ink, then drop all
        // per-page state.
        commitUncommittedIfNeeded(pageIndex: pageIndex, overlay: overlay)
        store.update(fullDrawings[pageIndex] ?? PKDrawing(), forPage: pageIndex)
        toolPicker.removeObserver(overlay.canvas)
        liveOverlays.removeValue(forKey: pageIndex)
        fullDrawings.removeValue(forKey: pageIndex)
        activeToolKind.removeValue(forKey: pageIndex)
        erasingPages.remove(pageIndex)
        isProgrammaticChange.remove(pageIndex)
        // Cancel/ignore any render still in flight for this page — its
        // result would otherwise apply to an overlay nothing displays
        // anymore.
        renderGeneration[pageIndex, default: 0] += 1
        pagesWithPenDown.remove(pageIndex)
        pagesChangedWhilePenDown.remove(pageIndex)
        idleFallbacks.removeValue(forKey: pageIndex)?.cancel()
        lastRenderScale.removeValue(forKey: pageIndex)
    }

    // MARK: - PKCanvasViewDelegate

    /// Which family of tool a page's current gesture belongs to, captured at
    /// `canvasViewDidBeginUsingTool` (S3 design note "Coordinator state").
    /// Inking is the common path (canvas stays empty, holding only the
    /// in-progress stroke); eraser/lasso need the full drawing loaded into
    /// the canvas to operate on.
    enum ToolKind {
        case inking
        case erasing
        case lasso
    }

    private var activeToolKind: [Int: ToolKind] = [:]

    /// Pages whose bitmap is currently hidden because the canvas holds the
    /// full drawing for an in-progress eraser/lasso gesture. `rerenderForZoom`
    /// skips these — the bitmap is hidden anyway, and the pen-up commit
    /// re-renders it regardless.
    private var erasingPages: Set<Int> = []

    /// Pages where `canvas.drawing` was just set by US, not the user (pen-up
    /// commit clearing the canvas, or an eraser/lasso gesture swapping the
    /// full drawing in). PencilKit posts `drawingDidChange` synchronously for
    /// a programmatic assignment same as a user edit, so without this guard
    /// our own clears/swaps would be mistaken for user changes and re-commit
    /// (S3 design note: "guard against treating our own programmatic clear as
    /// a user change").
    private var isProgrammaticChange: Set<Int> = []

    /// Pen-state bookkeeping, unchanged in shape from S2: PencilKit's
    /// delegate ordering around pen-up is not guaranteed and differs by tool
    /// (see `spec/notes/S2-option-b-crisp-ink.md` findings log) — the eraser
    /// commits to `drawing` ASYNCHRONOUSLY, so a render/commit triggered from
    /// pen-up must never be speculative. Commit when the model actually
    /// changed (`drawingDidChange` with the pen up, or at pen-up if a change
    /// already arrived mid-gesture); if nothing changes at all a short
    /// fallback still runs the commit (cheap: it's a no-op past the
    /// unchanged-drawing check).
    private var pagesWithPenDown: Set<Int> = []
    private var pagesChangedWhilePenDown: Set<Int> = []
    private var idleFallbacks: [Int: DispatchWorkItem] = [:]
    private static let idleFallbackDelay: TimeInterval = 0.25

    private static func toolKind(for tool: PKTool) -> ToolKind {
        if tool is PKEraserTool { return .erasing }
        if tool is PKLassoTool { return .lasso }
        return .inking
    }

    /// Sets `canvas.drawing` on our own behalf (not a user edit), guarding
    /// `canvasViewDrawingDidChange` against treating the resulting delegate
    /// call as one. Synchronous, so inserting/removing around the assignment
    /// is sufficient — PencilKit's delegate call (if any) happens inside it.
    private func setCanvasDrawing(_ drawing: PKDrawing, on canvas: PageCanvasView) {
        let pageIndex = canvas.pageIndex
        isProgrammaticChange.insert(pageIndex)
        canvas.drawing = drawing
        isProgrammaticChange.remove(pageIndex)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView,
              let overlay = liveOverlays[canvas.pageIndex]
        else { return }
        let pageIndex = canvas.pageIndex
        pagesWithPenDown.insert(pageIndex)
        pagesChangedWhilePenDown.remove(pageIndex)
        idleFallbacks.removeValue(forKey: pageIndex)?.cancel()

        let kind = Self.toolKind(for: canvas.tool)
        activeToolKind[pageIndex] = kind
        switch kind {
        case .inking:
            // Design note "Pen-down: nothing changes on screen" — the canvas
            // is already empty; PencilKit renders the in-progress stroke on
            // top of the (untouched, still-visible) bitmap.
            break
        case .erasing, .lasso:
            // Design note "Eraser / lasso": swap the full drawing into the
            // canvas and hide the bitmap in the same run-loop turn, before
            // the first touch renders, so there's something to erase/lasso
            // and the bitmap never shows stale content mid-gesture.
            erasingPages.insert(pageIndex)
            setCanvasDrawing(fullDrawings[pageIndex] ?? PKDrawing(), on: canvas)
            overlay.inkImageView.isHidden = true
        }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView else { return }
        let pageIndex = canvas.pageIndex
        pagesWithPenDown.remove(pageIndex)

        if pagesChangedWhilePenDown.remove(pageIndex) != nil {
            // The model already changed during the gesture: commit it now.
            commitPenUp(pageIndex: pageIndex)
            return
        }

        // Otherwise the change (if any) is still coming — asynchronously for
        // the eraser. `drawingDidChange` will commit it; if it never comes
        // (nothing changed at all), fall back to committing the unchanged
        // drawing, which is a cheap no-op past the equality check.
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, !self.pagesWithPenDown.contains(pageIndex) else { return }
            self.idleFallbacks.removeValue(forKey: pageIndex)
            self.commitPenUp(pageIndex: pageIndex)
        }
        idleFallbacks[pageIndex]?.cancel()
        idleFallbacks[pageIndex] = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleFallbackDelay, execute: fallback)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView else { return }
        let pageIndex = canvas.pageIndex

        guard !isProgrammaticChange.contains(pageIndex) else { return }

        if pagesWithPenDown.contains(pageIndex) {
            // Design note: "no-op (don't merge mid-stroke)" — remember only,
            // the pen-up handler does the actual commit.
            pagesChangedWhilePenDown.insert(pageIndex)
            return
        }

        // Pen is up: the just-finished stroke or erase landing (possibly
        // asynchronously), or an undo/redo/lasso change arriving from idle.
        idleFallbacks.removeValue(forKey: pageIndex)?.cancel()
        commitPenUp(pageIndex: pageIndex)
    }

    // MARK: - Commit (S3 design note "Inking path" / "Erasing/lasso path")

    private func commitPenUp(pageIndex: Int) {
        guard let overlay = liveOverlays[pageIndex], let pdfView = currentPDFView else { return }
        let canvas = overlay.canvas
        switch activeToolKind[pageIndex] ?? .inking {
        case .inking:
            commitInking(pageIndex: pageIndex, overlay: overlay, canvas: canvas, pdfView: pdfView)
        case .erasing, .lasso:
            commitErasingOrLasso(pageIndex: pageIndex, overlay: overlay, canvas: canvas, pdfView: pdfView)
        }
    }

    /// Appends the canvas's in-progress stroke onto `fullDrawings[pageIndex]`,
    /// persists, registers undo, and re-renders — clearing the canvas back to
    /// empty only once the new bitmap is ready (design note "the commit is:
    /// ... in the render completion (generation-checked) set `canvas.drawing
    /// = PKDrawing()`").
    private func commitInking(pageIndex: Int, overlay: PageOverlayView, canvas: PageCanvasView, pdfView: PDFView) {
        let newStrokes = canvas.drawing.strokes
        guard !newStrokes.isEmpty else { return }
        let previous = fullDrawings[pageIndex] ?? PKDrawing()
        let next = PKDrawing(strokes: previous.strokes + newStrokes)
        fullDrawings[pageIndex] = next
        registerUndo(page: pageIndex, previous: previous, next: next)
        store.update(next, forPage: pageIndex)
        render(pageIndex: pageIndex, drawing: next, overlay: overlay, pdfView: pdfView) { [weak self] in
            self?.finishGesture(pageIndex: pageIndex, canvas: canvas)
        }
    }

    /// Takes the canvas's (already erased/lasso-edited) drawing as the new
    /// truth if it actually differs, persists, registers undo, and
    /// re-renders — the canvas keeps showing the edited drawing until the new
    /// bitmap is ready, then both swap in the same turn, which is what
    /// removes the eraser ghost (design note: "Never show the old bitmap in
    /// between").
    private func commitErasingOrLasso(pageIndex: Int, overlay: PageOverlayView, canvas: PageCanvasView, pdfView: PDFView) {
        let previous = fullDrawings[pageIndex] ?? PKDrawing()
        let next = canvas.drawing
        if !Self.drawingsEqual(previous, next) {
            fullDrawings[pageIndex] = next
            registerUndo(page: pageIndex, previous: previous, next: next)
            store.update(next, forPage: pageIndex)
        }
        render(pageIndex: pageIndex, drawing: next, overlay: overlay, pdfView: pdfView) { [weak self] in
            self?.finishGesture(pageIndex: pageIndex, canvas: canvas)
        }
    }

    /// Shared render-completion tail for both commit paths: clear the canvas
    /// back to empty (the bitmap `apply(rendered:)` just unhid already shows
    /// the settled result, so there is nothing to lose) and stop treating the
    /// page as mid-eraser/lasso.
    private func finishGesture(pageIndex: Int, canvas: PageCanvasView) {
        setCanvasDrawing(PKDrawing(), on: canvas)
        erasingPages.remove(pageIndex)
    }

    /// Cheap "did this actually change" check — `PKDrawing` isn't Equatable.
    /// Stroke count and bounds reject the common "clearly different" case
    /// without touching serialization; only a real candidate match pays for
    /// `dataRepresentation()`.
    private static func drawingsEqual(_ a: PKDrawing, _ b: PKDrawing) -> Bool {
        guard a.strokes.count == b.strokes.count, a.bounds == b.bounds else { return false }
        return a.dataRepresentation() == b.dataRepresentation()
    }

    // MARK: - Undo / redo (S3 design note "Undo / redo")

    private func registerUndo(page: Int, previous: PKDrawing, next: PKDrawing) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyFullDrawing(previous, page: page, registeringRedoWith: next)
        }
    }

    /// Applies one undo/redo step: replaces the page's truth, persists,
    /// re-renders the bitmap, and registers the inverse so toolbar undo/redo
    /// keeps round-tripping. Never touches the canvas — an undo/redo is only
    /// ever invoked with the pen up, so the canvas is already empty (or, in
    /// the eraser/lasso case, about to be resynced by the next gesture).
    private func applyFullDrawing(_ drawing: PKDrawing, page: Int, registeringRedoWith redo: PKDrawing) {
        fullDrawings[page] = drawing
        store.update(drawing, forPage: page)
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyFullDrawing(redo, page: page, registeringRedoWith: drawing)
        }
        guard let overlay = liveOverlays[page], let pdfView = currentPDFView else { return }
        render(pageIndex: page, drawing: drawing, overlay: overlay, pdfView: pdfView)
    }

    // MARK: - Rendering (S2 "Rendering the image", scale math unchanged)

    /// Renders `drawing`'s settled strokes into `overlay.inkImageView` at a
    /// bitmap scale matched to the overlay's current on-screen magnification,
    /// so PDFKit's ancestor transform samples it 1:1 instead of bitmap-
    /// magnifying PencilKit's own (lower-resolution) rendering. `completion`
    /// runs after the bitmap is applied — synchronously for the "nothing to
    /// render" case, generation-checked (so a stale/cancelled render can't
    /// fire it) for the async case — letting callers do work (like clearing
    /// the canvas) that must happen no earlier than "the new bitmap is
    /// visible" (S3 design note).
    private func render(
        pageIndex: Int,
        drawing: PKDrawing,
        overlay: PageOverlayView,
        pdfView: PDFView,
        completion: (() -> Void)? = nil
    ) {
        let z = magnification(of: overlay, in: pdfView)
        let renderScale = min(UIScreen.main.scale * z, UIScreen.main.scale * Self.maxZoomForRender)

        let rect = drawing.bounds.insetBy(dx: -8, dy: -8).intersection(overlay.bounds)
        guard !drawing.strokes.isEmpty, !rect.isNull, !rect.isEmpty else {
            overlay.apply(rendered: nil)
            completion?()
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
                completion?()
            }
        }
    }

    /// Re-renders any page whose ink bitmap no longer matches the current
    /// on-screen zoom by more than 1% — called after the Reader's 150 ms
    /// zoom-settle debounce, and directly (cheap when nothing's changed) from
    /// layout passes and overlay recycling. Renders `fullDrawings[index]`,
    /// never `canvas.drawing` (S3: the canvas usually isn't holding the full
    /// drawing at all).
    func rerenderForZoom(in pdfView: PDFView) {
        currentPDFView = pdfView
        guard let referenceOverlay = liveOverlays.values.first else { return }
        let z = magnification(of: referenceOverlay, in: pdfView)
        let renderScale = min(UIScreen.main.scale * z, UIScreen.main.scale * Self.maxZoomForRender)

        for (index, overlay) in liveOverlays {
            // A page mid-eraser/lasso has its bitmap hidden already and
            // re-renders on pen-up regardless (design note "skip pages
            // currently erasing").
            guard !erasingPages.contains(index) else { continue }
            let previous = lastRenderScale[index] ?? 0
            guard previous <= 0 || abs(renderScale - previous) / previous > 0.01 else { continue }
            render(pageIndex: index, drawing: fullDrawings[index] ?? PKDrawing(), overlay: overlay, pdfView: pdfView)
        }
    }

    /// The on-screen magnification PDFKit is applying to this overlay's
    /// superview — same probe as spike S1, but only ever used to pick a
    /// bitmap render scale, never to transform a live view, so it cannot
    /// introduce drift. Falls back to 1 if the overlay isn't in the
    /// hierarchy yet.
    private func magnification(of overlay: PageOverlayView, in pdfView: PDFView) -> CGFloat {
        guard let superview = overlay.superview else { return 1 }
        let probe = superview.convert(CGRect(x: 0, y: 0, width: 100, height: 100), to: pdfView)
        let z = probe.width / 100
        guard z.isFinite, z > 0 else { return 1 }
        return z
    }

    // MARK: - Flush (SPEC §5.4 "Flush everything", S3 "Persistence"/"Recycling")

    /// Commits whatever the canvas currently holds into `fullDrawings`/the
    /// store WITHOUT touching the screen — used when the app is backgrounding
    /// (the overlay stays alive; a screen update would be invisible anyway)
    /// or a page is being recycled (about to be torn down regardless).
    /// Losing an in-progress gesture here would fail "kill mid-stroke-session
    /// → relaunch → all committed strokes present" (S3 acceptance #4).
    @discardableResult
    private func commitUncommittedIfNeeded(pageIndex: Int, overlay: PageOverlayView) -> Bool {
        let canvas = overlay.canvas
        guard !canvas.drawing.strokes.isEmpty else { return false }
        let previous = fullDrawings[pageIndex] ?? PKDrawing()
        let next: PKDrawing
        switch activeToolKind[pageIndex] ?? .inking {
        case .inking:
            next = PKDrawing(strokes: previous.strokes + canvas.drawing.strokes)
        case .erasing, .lasso:
            next = canvas.drawing
        }
        guard !Self.drawingsEqual(previous, next) else { return false }
        fullDrawings[pageIndex] = next
        registerUndo(page: pageIndex, previous: previous, next: next)
        store.update(next, forPage: pageIndex)
        return true
    }

    /// Pushes every currently-live overlay's drawing into the store. Called
    /// by the Reader before it saves position and flushes the store to disk
    /// — `willEndDisplayingOverlayView` only fires for pages that actually
    /// scroll off, not for the ones still on screen when the app backgrounds.
    func pushLiveDrawingsToStore() {
        for (index, overlay) in liveOverlays {
            commitUncommittedIfNeeded(pageIndex: index, overlay: overlay)
            store.update(fullDrawings[index] ?? PKDrawing(), forPage: index)
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
