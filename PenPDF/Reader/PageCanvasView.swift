import PencilKit
import UIKit

/// The ink layer for a single PDF page (SPEC §5.6).
final class PageCanvasView: PKCanvasView {

    var pageIndex: Int = 0

    /// Never steal first responder. The tool picker is anchored to the
    /// Reader's `ResponderView`; if a canvas grabbed first responder mid-touch
    /// the palette would hide right as a stroke starts. Drawing does not
    /// require being first responder, and undo still resolves up the
    /// responder chain to the Reader.
    override var canBecomeFirstResponder: Bool { false }

    /// S3 (`spec/notes/S3-stroke-only-canvas.md` "Undo / redo"): under S3 the
    /// canvas is cleared back to an empty `PKDrawing` right after every
    /// commit (inking) or gesture (erase/lasso), so PencilKit's own automatic
    /// undo registrations — made against whatever `UndoManager` the responder
    /// chain resolves for this view — would target strokes that no longer
    /// live on the canvas by the time the toolbar's Undo is tapped. Returning
    /// `nil` stops PencilKit registering anything here at all;
    /// `InkOverlayCoordinator` registers the real (full-drawing) undo/redo
    /// steps into the Reader's shared manager instead.
    override var undoManager: UndoManager? { nil }
}
