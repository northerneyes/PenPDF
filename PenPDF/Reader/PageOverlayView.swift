import PencilKit
import UIKit

/// A rendered snapshot of a page's settled ink strokes: the bitmap
/// `InkOverlayCoordinator.render` produces from `PKDrawing.image(from:scale:)`,
/// plus the rect (in `PageOverlayView`'s own coordinate space) it covers.
/// See `spec/notes/S2-option-b-crisp-ink.md` "Rendering the image" (the
/// render-scale trick is unchanged by S3).
struct RenderedInk {
    let image: UIImage
    let rect: CGRect
}

/// Per-page overlay returned to PDFKit. Hosts two children:
/// - `inkImageView`: the page's settled strokes (`InkOverlayCoordinator`'s
///   `fullDrawings[page]`), rendered to a bitmap at `screenScale × zoom` so it
///   is sampled 1:1 through PDFKit's ancestor transform — crisp. A plain
///   `UIImageView`/`CALayer` honours its bitmap's `contentsScale`; `PKCanvasView`
///   does not (`spec/notes/S2-option-b-crisp-ink.md` "Why").
/// - `canvas`: the live `PKCanvasView` (§5.6, unchanged). S3
///   (`spec/notes/S3-stroke-only-canvas.md`): unlike S2, the canvas does NOT
///   hold the full drawing at all times — it is empty except for an
///   in-progress stroke (inking) or, briefly, the full drawing while an
///   eraser/lasso gesture is in progress. It is never hidden via `alpha` or a
///   layer mask (that trick, and the S2 idle/drawing mode swap it supported,
///   is gone): an empty canvas is naturally invisible, so it can stay a
///   normal, fully hit-testable view at all times.
///
/// PDFKit owns this view's frame entirely, exactly like the canvas it
/// replaces (§5.4 "Overlay for page") — never set frame/bounds/transform on
/// it or on `canvas`; both children fill it via autoresizing. The only frame
/// this class ever sets is `inkImageView.frame` in `apply(rendered:)`, on its
/// own child, in its own coordinate space (which PDFKit's ancestor transform
/// scales along with everything else) — sanctioned by the S2 design note.
final class PageOverlayView: UIView {

    let canvas: PageCanvasView
    let inkImageView = UIImageView()

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

        // Ink image below, canvas above: the canvas only ever shows the
        // stroke being drawn right now (inking) or, briefly, the full
        // drawing during an eraser/lasso gesture (with the ink image hidden
        // for that duration) — never both at once showing different content
        // (S3 invariant: "settled ink never changes appearance at pen-down or
        // pen-up").
        addSubview(inkImageView)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Swaps in a freshly rendered bitmap of the settled strokes, or clears
    /// it when the drawing has no ink to show. Manages its own visibility
    /// (`isHidden`) so every call site gets "no image ⇒ hidden, image ⇒
    /// visible" for free — the coordinator only ever needs to hide it early
    /// (before an eraser/lasso gesture starts drawing into the canvas); this
    /// is what unhides it again once the new bitmap is actually ready, so a
    /// stale image is never shown mid-swap (S3 design note "Eraser / lasso":
    /// "never show the old bitmap in between").
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
        inkImageView.isHidden = false
    }

    /// Ink off (`canvas.isUserInteractionEnabled == false`, FR-18a debug
    /// toggle): return nil so touches fall through to PDFView underneath,
    /// unchanged from `main`. Otherwise normal hit-testing, which descends
    /// into the canvas's internal subviews where PencilKit's stroke
    /// recognizer lives — safe now because the canvas is never hidden via
    /// `alpha`/mask (S3 removed the S2 mask trick that existed only to keep
    /// hit-testing working on a hidden canvas).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard canvas.isUserInteractionEnabled else { return nil }
        return super.hitTest(point, with: event)
    }
}
