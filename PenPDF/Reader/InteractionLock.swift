import PDFKit
import PencilKit
import UIKit
import os.log

/// Lock mode / "paper mode" (SPEC §3.5, §5.7). Disables every finger gesture
/// recognizer and scroll view under a root view (typically `pdfView`) while
/// leaving `PKCanvasView`s — and therefore the Pencil — completely untouched.
///
/// No hit-test tricks: this is the primary, deterministic approach from
/// §5.7 steps 1–5. The `TouchShield` fallback described there was not needed.
final class InteractionLock {

    private static let log = OSLog(subsystem: "com.georgebuhanov.penpdf", category: "InteractionLock")

    private var disabledRecognizers: [ObjectIdentifier: (recognizer: UIGestureRecognizer, wasEnabled: Bool)] = [:]
    private var disabledScrollViews: [ObjectIdentifier: (scrollView: UIScrollView, wasEnabled: Bool)] = [:]
    private(set) var isLocked = false

    /// Turns lock ON: walks `root`, disabling every finger gesture recognizer
    /// and scroll view it finds (skipping ink canvases), and clears any live
    /// text selection so it doesn't linger while the document is inert.
    func lock(_ root: UIView) {
        isLocked = true
        if let pdfView = root as? PDFView {
            pdfView.clearSelection()
        }
        walk(root)
        os_log(
            "lock: %d recognizers disabled, %d scroll views disabled",
            log: Self.log, type: .debug,
            disabledRecognizers.count, disabledScrollViews.count
        )
    }

    /// PDFKit adds internal recognizers/scroll views lazily as pages are laid
    /// out. Call from every `viewDidLayoutSubviews` while locked; it only
    /// records views not yet seen, so it never clobbers an already-recorded
    /// restore value.
    func reapplyIfLocked(_ root: UIView) {
        guard isLocked else { return }
        let recognizersBefore = disabledRecognizers.count
        let scrollViewsBefore = disabledScrollViews.count
        walk(root)
        let newRecognizers = disabledRecognizers.count - recognizersBefore
        let newScrollViews = disabledScrollViews.count - scrollViewsBefore
        if newRecognizers > 0 || newScrollViews > 0 {
            os_log(
                "reapplyIfLocked: %d new recognizers disabled, %d new scroll views disabled",
                log: Self.log, type: .debug,
                newRecognizers, newScrollViews
            )
        }
    }

    /// Turns lock OFF: restores every recorded `isEnabled`/`isScrollEnabled`
    /// to what it was before locking.
    func unlock() {
        for (_, entry) in disabledRecognizers {
            entry.recognizer.isEnabled = entry.wasEnabled
        }
        for (_, entry) in disabledScrollViews {
            entry.scrollView.isScrollEnabled = entry.wasEnabled
        }
        os_log(
            "unlock: %d recognizers restored, %d scroll views restored",
            log: Self.log, type: .debug,
            disabledRecognizers.count, disabledScrollViews.count
        )
        disabledRecognizers.removeAll()
        disabledScrollViews.removeAll()
        isLocked = false
    }

    // MARK: - Private

    /// Depth-first. Skips any `PKCanvasView` and its entire subtree so Pencil
    /// input into the ink layer is never touched.
    private func walk(_ view: UIView) {
        if view is PKCanvasView { return }

        for recognizer in view.gestureRecognizers ?? [] {
            let id = ObjectIdentifier(recognizer)
            guard disabledRecognizers[id] == nil else { continue }
            disabledRecognizers[id] = (recognizer, recognizer.isEnabled)
            recognizer.isEnabled = false
        }

        if let scrollView = view as? UIScrollView {
            let id = ObjectIdentifier(scrollView)
            if disabledScrollViews[id] == nil {
                disabledScrollViews[id] = (scrollView, scrollView.isScrollEnabled)
                scrollView.isScrollEnabled = false
            }
            // Already covered by the gestureRecognizers loop above, but §5.7
            // step 2 calls these out explicitly — be explicit here too.
            scrollView.pinchGestureRecognizer?.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = false
        }

        for subview in view.subviews {
            walk(subview)
        }
    }
}
