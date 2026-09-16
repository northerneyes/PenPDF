import PencilKit
import UIKit

/// The single screen-scale ink canvas (spike S5, `spec/notes/S5-screen-canvas.md`).
///
/// Unlike the retired `PageCanvasView` (one per page, living INSIDE PDFKit's
/// page overlay tree and therefore bitmap-magnified by PDFKit's ancestor
/// transform at any zoom — Apple DTS: no workaround, see `deferred.md`), this
/// is ONE canvas that sits as a SIBLING above `pdfView` at native screen
/// scale, never scrolled or zoomed by the user and never a descendant of
/// PDFView. PencilKit therefore always renders at 1:1 screen resolution with
/// its full low-latency pipeline, regardless of the PDF's zoom level.
///
/// This view is a pure DISPLAY surface: `ScreenInkController` is the only
/// thing that ever assigns `drawing` (from `DocumentStore`, transformed into
/// screen space) or reads it back (to diff and commit into per-page store
/// drawings). The canvas itself is never the source of truth.
final class ScreenCanvasView: PKCanvasView {

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Never scrolled/zoomed by the user — `pdfView` alone owns panning
        // and zooming; this canvas only ever shows a screen-space projection
        // of the document's ink, recomputed by `ScreenInkController` whenever
        // `pdfView` moves.
        isScrollEnabled = false
        minimumZoomScale = 1
        maximumZoomScale = 1
        backgroundColor = .clear
        isOpaque = false
        scrollsToTop = false
        contentInsetAdjustmentBehavior = .never

        // SPEC §5.6 / S5 note: the simulator has no Apple Pencil, so smoke
        // testing needs mouse input to draw at all; never relaxed on device.
        #if targetEnvironment(simulator)
        drawingPolicy = .anyInput
        #else
        drawingPolicy = .pencilOnly
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Never steal first responder. The tool picker is anchored to the
    /// Reader's `ResponderView`; if the canvas grabbed first responder
    /// mid-touch the palette would hide right as a stroke starts.
    override var canBecomeFirstResponder: Bool { false }

    /// Explicit, page-scoped undo lives in `ScreenInkController`
    /// (`registerUndo`/`applyPageDrawing`) — PencilKit must never register
    /// its own undo actions against the responder chain's `UndoManager` for
    /// this canvas, since the canvas holds a transient screen-space
    /// projection, not any single page's actual drawing.
    override var undoManager: UndoManager? { nil }

    /// Routes fingers to `PDFView` underneath and Pencil touches to this
    /// canvas (SPEC §3.4 / S5 note).
    ///
    /// FR-18a debug ink-off: `isUserInteractionEnabled == false` fails the
    /// first guard, so everything falls through to `PDFView` unconditionally.
    ///
    /// Observed on the Simulator (`F30083E9-...`): there is no Apple Pencil,
    /// and the mouse is delivered as a `.direct` (finger-like) touch, exactly
    /// like `UIEvent` documents for `.anyInput`/no-pencil environments — so
    /// on `targetEnvironment(simulator)` the pencil-type check below is
    /// skipped entirely and the canvas takes ANY touch, matching
    /// `drawingPolicy = .anyInput` set above. On device this branch is
    /// compiled out; only a genuine `.pencil` touch reaches the canvas.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, bounds.contains(point) else { return nil }

        #if targetEnvironment(simulator)
        return super.hitTest(point, with: event)
        #else
        guard let touches = event?.allTouches, !touches.isEmpty else {
            // `event.allTouches` can be nil on some hit-test paths (observed
            // during PDFKit's own gesture-recognizer probing, before any
            // touch is actually delivered). We cannot positively identify a
            // direct/finger touch here, so prefer letting the canvas have
            // the hit-test result over wrongly rejecting a Pencil touch:
            // `drawingPolicy = .pencilOnly` means PencilKit itself silently
            // ignores a finger that does land here anyway. The trade-off
            // (per the S5 note) is that PDFView's pan/pinch recognizers
            // underneath may not see that one touch for this hit-test pass.
            return super.hitTest(point, with: event)
        }
        let hasPencilTouch = touches.contains { $0.type == .pencil }
        guard hasPencilTouch else {
            // No touch in this event is a Pencil touch: let it fall straight
            // through to PDFView (palm rest, finger pan/pinch, FR-32
            // two-finger pan) rather than have PencilKit merely ignore it.
            return nil
        }
        return super.hitTest(point, with: event)
        #endif
    }
}
