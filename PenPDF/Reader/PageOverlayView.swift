import PencilKit
import UIKit

/// A rendered snapshot of a page's settled ink strokes: the bitmap
/// `InkOverlayCoordinator.render` produces from `PKDrawing.image(from:scale:)`,
/// plus the rect (in `PageOverlayView`'s own coordinate space) it covers.
/// See `spec/notes/S2-option-b-crisp-ink.md` "Rendering the image".
struct RenderedInk {
    let image: UIImage
    let rect: CGRect
}

/// Per-page overlay returned to PDFKit (S2 Option B,
/// `spec/notes/S2-option-b-crisp-ink.md`). Replaces the bare `PageCanvasView`
/// that PDFKit used to receive directly. Hosts two children:
/// - `inkImageView`: the page's settled strokes, rendered to a bitmap at
///   `screenScale × zoom` so it is sampled 1:1 through PDFKit's ancestor
///   transform — crisp. A plain `UIImageView`/`CALayer` honours its bitmap's
///   `contentsScale`; `PKCanvasView` does not (see the note's "Why").
/// - `canvas`: the live `PKCanvasView` (§5.6, unchanged), which always holds
///   the FULL drawing and is the only thing that actually receives Pencil
///   input.
///
/// PDFKit owns this view's frame entirely, exactly like the canvas it
/// replaces (§5.4 "Overlay for page") — never set frame/bounds/transform on
/// it or on `canvas`; both children fill it via autoresizing. The only frame
/// this class ever sets is `inkImageView.frame` in `apply(rendered:)`, on its
/// own child, in its own coordinate space (which PDFKit's ancestor transform
/// scales along with everything else) — sanctioned by the design note.
final class PageOverlayView: UIView {

    enum Mode {
        case idle
        case drawing
    }

    let canvas: PageCanvasView
    let inkImageView = UIImageView()

    private(set) var mode: Mode = .idle

    init(canvas: PageCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)

        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        inkImageView.isUserInteractionEnabled = false
        // The frame IS the rendered rect (`apply(rendered:)` sets it exactly
        // to what was rendered), so there is no aspect mismatch to resolve.
        inkImageView.contentMode = .scaleToFill
        inkImageView.isOpaque = false
        inkImageView.backgroundColor = .clear
        inkImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        inkImageView.isHidden = true

        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Ink image below, canvas above: while drawing, the live canvas (with
        // the in-progress stroke) must win visually; while idle the canvas is
        // invisible (alpha 0) so draw order doesn't matter, but this keeps
        // the stacking sane in both modes.
        addSubview(inkImageView)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hides the idle canvas WITHOUT using `alpha`/`isHidden`. Those two make
    /// UIKit's hit-testing skip the view — and PencilKit's stroke recognizer
    /// lives on an internal subview of the canvas, which only receives a
    /// touch if hit-testing descends into it normally. A `layer.mask` with
    /// zero size renders nothing but is ignored by hit-testing, so the
    /// invisible canvas keeps receiving Pencil input exactly as on `main`.
    private let hiddenMask: CALayer = {
        let layer = CALayer()
        layer.frame = .zero
        return layer
    }()

    /// Idle: strokes are shown via the crisp image layer; the canvas is
    /// masked out but still live — still holds the full drawing and still
    /// receives Pencil input. Drawing: the reverse, so the in-progress stroke
    /// (and the rest of the page's ink, rendered live by PencilKit) is
    /// visible — soft at high zoom only while the pen is down (design note
    /// "Design (per page overlay)").
    /// S4 experiment: when true the canvas is NEVER shown — it only takes
    /// Pencil input and holds the drawing; the crisp bitmap is re-rendered on
    /// every drawing change while the pen is down, so what the user sees is
    /// always the bitmap (`spec/notes/S4-live-bitmap.md`).
    var liveBitmap = false

    func setMode(_ newMode: Mode) {
        mode = newMode
        switch newMode {
        case .idle:
            canvas.layer.mask = hiddenMask
            inkImageView.isHidden = (inkImageView.image == nil)
        case .drawing:
            if liveBitmap {
                canvas.layer.mask = hiddenMask       // stays invisible
                // bitmap stays visible; live renders replace it continuously
            } else {
                canvas.layer.mask = nil
                inkImageView.isHidden = true
            }
        }
    }

    /// Swaps in a freshly rendered bitmap of the settled strokes, or clears
    /// it when the drawing has no ink to show. Visibility on the non-nil path
    /// is left to a subsequent `setMode` call (every call site in
    /// `InkOverlayCoordinator.render` follows this with one) so a stale image
    /// is never shown mid-swap — no flash, no ghosting (design note "Pen up").
    func apply(rendered: RenderedInk?) {
        guard let rendered else {
            inkImageView.image = nil
            inkImageView.isHidden = true
            return
        }
        // Positioned explicitly by rect from here on, not by container fill.
        inkImageView.autoresizingMask = []
        inkImageView.image = rendered.image
        inkImageView.frame = rendered.rect
        // S4: the bitmap is the only thing ever shown, so a page that had no
        // ink (image nil → hidden) must become visible on its first live
        // render, not wait for pen-up.
        if liveBitmap { inkImageView.isHidden = false }
    }

    /// Ink off (`canvas.isUserInteractionEnabled == false`, FR-18a debug
    /// toggle): return nil so touches fall through to PDFView underneath,
    /// unchanged from `main`. Otherwise normal hit-testing, which descends
    /// into the canvas's internal subviews — where PencilKit's stroke
    /// recognizer is (see `hiddenMask` for why the canvas must not be hidden
    /// via alpha).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard canvas.isUserInteractionEnabled else { return nil }
        return super.hitTest(point, with: event)
    }
}
