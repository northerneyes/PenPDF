import UIKit

/// The Reader's root view. It exists solely so the Reader has a first
/// responder to anchor the `PKToolPicker` to (WP4) — PencilKit's palette is
/// shown/hidden relative to whatever view is first responder, not to the
/// PDFView itself.
final class ResponderView: UIView {
    override var canBecomeFirstResponder: Bool { true }
}
