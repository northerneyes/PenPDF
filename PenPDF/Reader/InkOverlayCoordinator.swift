import PDFKit
import PencilKit
import UIKit
#if DEBUG
import os.log
#endif

/// Bridges PDFKit's page overlay mechanism to PencilKit (SPEC §3.4, §5.4).
///
/// One `PageCanvasView` exists per page PDFKit is currently displaying.
/// PDFKit asks for a canvas as a page scrolls on screen and tells us when it
/// scrolls off; in between, strokes flow through `PKCanvasViewDelegate` into
/// `DocumentStore`. PDFKit owns a canvas's `frame` entirely (SPEC §5.4
/// "Overlay for page") — never set it. The one sanctioned exception is
/// `applyCrispZoom` below (spike S1, `deferred.md`), which sets `zoomScale`
/// and a counter-`transform` so PencilKit renders at true resolution while
/// the on-screen frame (derived, under a transform) stays exactly what
/// PDFKit assigned.
final class InkOverlayCoordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {

    private let document: PDFDocument
    private let store: DocumentStore
    private let toolPicker: PKToolPicker

    private var liveCanvases: [Int: PageCanvasView] = [:]

    /// Spike S1 (deferred.md "Crisp ink at zoom"): one flag reverts the whole
    /// experiment to SPEC-baseline geometry (no transform, `zoomScale == 1`).
    var crispZoomEnabled = false   // S1 failed on owner test 2026-09-15: ink drifted off the page after repeated large zooms. Keep off; see deferred.md.

    /// Cap on the PencilKit-native zoom applied to a canvas, independent of
    /// how far PDFKit itself is zoomed — bounds the canvas's drawable/backing
    /// memory (SPEC NFR-3).
    private static let maxCrispZoom: CGFloat = 4

    #if DEBUG
    private static let crispZoomLog = OSLog(subsystem: "com.georgebuhanov.penpdf", category: "CrispZoom")
    /// Last `z` logged per page index, so diagnostics only fire when it changes.
    private var lastLoggedZoom: [Int: CGFloat] = [:]
    #endif

    /// FR-18a: ON (the default, every launch, never persisted) makes the
    /// Pencil draw, like Apple Notes. OFF makes the Pencil behave exactly
    /// like a finger — Preview's markup button does the same thing — which
    /// in the simulator (mouse == finger, `anyInput`) is the only way to
    /// scroll a page without drawing on it.
    private(set) var isInkEnabled = true

    init(document: PDFDocument, store: DocumentStore, toolPicker: PKToolPicker) {
        self.document = document
        self.store = store
        self.toolPicker = toolPicker
        super.init()
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }

        if let existing = liveCanvases[index] {
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
        canvas.drawing = store.drawing(forPage: index)
        canvas.tool = toolPicker.selectedTool
        // FR-18a: a canvas created while ink is toggled off must come up
        // inert too, so it doesn't grab pages scrolled in after the toggle.
        canvas.isUserInteractionEnabled = isInkEnabled
        toolPicker.addObserver(canvas)

        liveCanvases[index] = canvas
        // Spike S1: a freshly-created canvas should start at the right
        // PencilKit-native zoom for the current on-screen magnification, not
        // just pick it up on the next `.PDFViewScaleChanged`. PDFKit hasn't
        // necessarily assigned `frame` yet at this point, but `superview` is
        // already set (PDFKit adds the overlay to its hierarchy before
        // returning from this call), so the probe below still works; it is
        // re-applied from `willDisplayOverlayView` once PDFKit has placed it.
        if crispZoomEnabled { applyCrispZoom(settledZ, to: canvas) }
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        // Spike S1: PDFKit has assigned the overlay's frame by now, so the
        // superview-magnification probe reflects the real on-screen size.
        guard let canvas = overlayView as? PageCanvasView else { return }
        if crispZoomEnabled { applyCrispZoom(settledZ, to: canvas) }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PageCanvasView else { return }
        store.update(canvas.drawing, forPage: canvas.pageIndex)
        toolPicker.removeObserver(canvas)
        liveCanvases.removeValue(forKey: canvas.pageIndex)
        #if DEBUG
        lastLoggedZoom.removeValue(forKey: canvas.pageIndex)
        #endif
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView else { return }
        store.update(canvas.drawing, forPage: canvas.pageIndex)
    }

    // MARK: - Flush (SPEC §5.4 "Flush everything")

    /// Pushes every currently-live canvas's drawing into the store. Called by
    /// the Reader before it saves position and flushes the store to disk —
    /// `willEndDisplayingOverlayView` only fires for pages that actually
    /// scroll off, not for the ones still on screen when the app backgrounds.
    func pushLiveDrawingsToStore() {
        for (index, canvas) in liveCanvases {
            store.update(canvas.drawing, forPage: index)
        }
    }

    // MARK: - Crisp zoom (spike S1 — deferred.md "Crisp ink at zoom", experiment A failed)

    /// Experiment A (WP6, `contentScaleFactor` propagation) did not fix the
    /// blur: PDFKit magnifies the overlay by scaling its existing raster via
    /// an ancestor transform rather than re-rendering it, so PencilKit's
    /// vector strokes come out bitmap-magnified no matter what contents-scale
    /// hint the canvas is given — PencilKit renders crisply at its own
    /// `zoomScale`, not at an external hint. S1 instead drives PencilKit's
    /// *native* zoom (as Notes does): set the canvas's own `zoomScale` to the
    /// on-screen magnification `z` PDFKit is applying to its superview, then
    /// counter-transform the canvas by `1/z` so its on-screen frame is
    /// unchanged. Because a view's `frame` under a transform is a derived
    /// property, PDFKit's own `frame = pageRect` assignments automatically
    /// produce `bounds = pageRect × z` — exactly the resolution PencilKit
    /// needs to draw crisply, with no visible size or position change. This
    /// is the one sanctioned exception to SPEC §5.4 "do not set frame/transform".
    /// Live-pinch rule: PDFKit re-scales the ancestor continuously while the
    /// user pinches. Re-applying `zoomScale` on every layout pass made
    /// PencilKit re-rasterize mid-gesture and the ink visibly jumped. The
    /// ink's on-screen POSITION is correct regardless of our `z` (screen =
    /// p × ancestor scale), only its resolution lags — so canvases are left
    /// alone while `z` is moving and re-rendered once it has been stable for
    /// `settleDelay`, like a PDF viewer rasterising after a zoom ends.
    private var settledZ: CGFloat = 1
    private var settleWork: DispatchWorkItem?
    private static let settleDelay: TimeInterval = 0.15

    func updateCrispZoom(for pdfView: PDFView) {
        guard crispZoomEnabled else {
            settleWork?.cancel()
            settleWork = nil
            for canvas in liveCanvases.values { resetCrispZoom(on: canvas) }
            return
        }
        guard let z = currentMagnification(in: pdfView) else { return }

        if abs(z - settledZ) < 0.001 {
            // Stable: make sure every live canvas (incl. ones PDFKit just
            // re-framed or created) is at the settled value. Idempotent.
            settleWork?.cancel()
            settleWork = nil
            for canvas in liveCanvases.values { applyCrispZoom(z, to: canvas) }
            return
        }

        // Moving: wait for quiet, then re-measure and apply once.
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak pdfView] in
            guard let self, let pdfView, let z = self.currentMagnification(in: pdfView) else { return }
            self.settledZ = z
            self.settleWork = nil
            for canvas in self.liveCanvases.values { self.applyCrispZoom(z, to: canvas) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// The on-screen magnification PDFKit applies to page overlays, probed
    /// from a live canvas's superview — independent of any transform we put
    /// on the canvas itself (probing the canvas would be circular). `pdfView`
    /// is the reference so the window's own scale doesn't leak in. Capped.
    private func currentMagnification(in pdfView: PDFView) -> CGFloat? {
        guard let superview = liveCanvases.values.first?.superview else { return nil }
        let probe = superview.convert(CGRect(x: 0, y: 0, width: 100, height: 100), to: pdfView)
        let z = probe.width / 100
        guard z.isFinite, z > 0 else { return nil }
        return min(z, Self.maxCrispZoom)
    }

    /// Back to spec-baseline geometry (flag off).
    private func resetCrispZoom(on canvas: PageCanvasView) {
        guard canvas.transform != .identity || canvas.zoomScale != 1 else { return }
        let onScreenFrame = canvas.frame
        canvas.transform = .identity
        canvas.frame = onScreenFrame          // restore PDFKit's extent
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.zoomScale = 1
    }

    /// Applies a settled `z` to one canvas. Idempotent; safe on every signal.
    private func applyCrispZoom(_ z: CGFloat, to canvas: PageCanvasView) {
        // The on-screen rect PDFKit gave this overlay (the page rect in its
        // superview's coordinates). `frame` is derived from bounds × transform,
        // so re-assigning it after switching the transform is what grows the
        // bounds to pageRect × z. At creation PDFKit hasn't laid the overlay
        // out yet (frame is zero): skip, `willDisplayOverlayView` calls again.
        let onScreenFrame = canvas.frame
        guard !onScreenFrame.isEmpty else { return }

        if abs(canvas.zoomScale - z) < 0.001,
           canvas.transform == CGAffineTransform(scaleX: 1 / z, y: 1 / z),
           abs(canvas.bounds.width - onScreenFrame.width * z) < 0.5 {
            return
        }

        #if DEBUG
        let didChangeZoomForLog = lastLoggedZoom[canvas.pageIndex] != z
        #endif

        // Order: counter-transform, then re-assign the SAME on-screen frame
        // (bounds ⇒ pageRect × z so the whole page stays drawable — without
        // it the canvas covers only the top-left 1/z of the page and clips
        // strokes outside it), then PencilKit's zoom so strokes render at
        // true resolution, then `contentOffset` reset last.
        canvas.transform = CGAffineTransform(scaleX: 1 / z, y: 1 / z)
        canvas.frame = onScreenFrame
        canvas.minimumZoomScale = z
        canvas.maximumZoomScale = z
        canvas.zoomScale = z
        canvas.contentOffset = .zero

        #if DEBUG
        if didChangeZoomForLog {
            lastLoggedZoom[canvas.pageIndex] = z
            os_log(
                .debug,
                log: Self.crispZoomLog,
                "page=%d z=%.3f canvas.bounds=%{public}@ canvas.frame=%{public}@",
                canvas.pageIndex,
                z,
                NSCoder.string(for: canvas.bounds.size),
                NSCoder.string(for: canvas.frame.size)
            )
        }
        #endif
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
    /// again), and follows with the palette's visibility.
    func setInkEnabled(_ enabled: Bool, for responder: UIResponder) {
        isInkEnabled = enabled
        for canvas in liveCanvases.values {
            canvas.isUserInteractionEnabled = enabled
        }
        toolPicker.setVisible(enabled, forFirstResponder: responder)
    }
}
