import PencilKit
import UIKit

/// The ink layer for a single PDF page.
final class PageCanvasView: PKCanvasView {

    var pageIndex: Int = 0

    /// Never steal first responder. The tool picker is anchored to the reader's
    /// root view; if a canvas grabbed first responder on touch the palette would
    /// flicker away mid-stroke. Drawing does not require being first responder,
    /// and undo still resolves up the responder chain to the view controller.
    override var canBecomeFirstResponder: Bool { false }
}

/// Root view of the reader. Exists purely so `PKToolPicker` has a stable
/// responder to attach itself to across page changes.
final class ResponderView: UIView {
    override var canBecomeFirstResponder: Bool { true }
}
