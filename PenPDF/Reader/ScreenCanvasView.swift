import PencilKit
import UIKit

/// The single screen-scale ink canvas (spike S5, `spec/notes/S5-screen-canvas.md`).
///
/// Lives INSIDE PDFKit's scroll view as a sibling of the zoomed document view
/// (never a descendant of it, so it is never magnified by the zoom transform
/// — Apple DTS: a `PKCanvasView` under a scaled ancestor has no crisp-zoom
/// workaround, see `deferred.md`). PencilKit therefore always renders at 1:1
/// screen resolution with its full low-latency pipeline, regardless of the
/// PDF's zoom level.
///
/// Being a descendant of PDFKit's scroll view is also what makes navigation
/// work with no touch routing code: every finger touch hit-tested to this
/// canvas is still seen by the scroll view's own pan/pinch recognisers (UIKit
/// delivers touches to ancestors' recognisers), so scrolling, inertia,
/// two-finger pan (FR-32) and pinch are all PDFKit's native behaviour, while
/// `drawingPolicy = .pencilOnly` means PencilKit ignores those same fingers.
///
/// This view is a pure DISPLAY surface: `ScreenInkController` is the only
/// thing that ever assigns `drawing` (the store's page drawings projected
/// into scroll-content coordinates) or reads it back to commit strokes into
/// per-page store drawings. The canvas is never the source of truth.
final class ScreenCanvasView: PKCanvasView {

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Never scrolled/zoomed by the user — PDFKit's scroll view owns
        // panning and zooming. `contentOffset` IS driven programmatically by
        // `ScreenInkController` to mirror the outer scroll view (so content
        // coordinates == document coordinates and ink stays glued to the
        // page during scrolling with no re-projection).
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

    /// Explicit, page-scoped undo lives in `ScreenInkController` — PencilKit
    /// must never register its own undo actions against the responder
    /// chain's `UndoManager` for this canvas, since the canvas holds a
    /// transient projection, not any single page's actual drawing.
    override var undoManager: UndoManager? { nil }

    /// FR-18a debug ink-off: `isUserInteractionEnabled == false` makes UIKit
    /// skip this view entirely, so touches fall through to PDFKit's document
    /// view (links, selection) as on a plain PDFView. Otherwise default
    /// hit-testing — no pencil/finger guessing: `event.allTouches` is nil
    /// during hit-testing for new touches (S5 device finding), so any
    /// decision made here was wrong half the time. Fingers reaching this
    /// canvas are harmless: PencilKit ignores them and the ancestor scroll
    /// view handles them.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled else { return nil }
        return super.hitTest(point, with: event)
    }
}
