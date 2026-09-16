import PDFKit
import UIKit

/// Resize/rotation settling-window mechanics (FR-10 / F1, SPEC §5.4
/// "Rotation / resize"). Split out of `ReaderViewController.swift` in WP6
/// (behaviour-neutral refactor). `viewWillTransition` itself stays on the
/// main file: it's a UIKit override, and overrides of non-`@objc`-dynamic
/// members are safest kept where the class body is, not in an extension.
extension ReaderViewController {

    /// Scrolls back to the pinned page/point. Idempotent; safe to call often.
    func applyResizePin() {
        guard let pin = resizePin else { return }
        if let point = pin.point {
            pdfView.go(to: PDFDestination(page: pin.page, at: point))
        } else {
            pdfView.go(to: pin.page)
        }
    }

    /// (Re)starts the quiet timer. When PDFKit has been silent for 0.4 s the
    /// resize is considered settled: pin one final time, drop the window,
    /// refresh the title, and only then let position saves resume.
    func scheduleResizeWindowEnd() {
        resizeWindowEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyResizePin()
            self.resizePin = nil
            self.resizeWindowEnd = nil
            self.updateTitle()
            self.updatePageButtons()
            self.savePosition()
        }
        resizeWindowEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
