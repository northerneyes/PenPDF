import UIKit

/// Debug-only ink on/off toggle (FR-18a) — lets the simulator's mouse (which
/// the system treats as a finger under `anyInput`) scroll a page without
/// drawing on it. Split out of `ReaderViewController.swift` in WP6
/// (behaviour-neutral refactor). Absent entirely from Release builds.
#if DEBUG
extension ReaderViewController {

    /// FR-18a, debug builds only: makes the Pencil (or the simulator's mouse)
    /// behave like a finger so a page can be scrolled without drawing on it.
    /// S5: `pdfView.isInMarkupMode` is always `false` now (ink no longer
    /// routes through PDFKit at all — see `ReaderViewController.viewDidLoad`)
    /// so there is nothing to toggle there; `ink.canvas.isUserInteractionEnabled`
    /// is the only switch.
    @objc func didTapDebugInkToggle() {
        ink.setInkEnabled(!ink.isInkEnabled, for: view)
        if ink.isInkEnabled, !view.isFirstResponder {
            view.becomeFirstResponder()
        }
        applyDebugInkState()
    }

    func applyDebugInkState() {
        debugInkToggleButton.tintColor = ink.isInkEnabled ? nil : .systemRed
    }
}
#endif
