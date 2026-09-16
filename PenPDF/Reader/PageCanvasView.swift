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
}
