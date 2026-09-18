import UIKit

/// Lock-state application (WP5, FR-23…FR-26). Split out of
/// `ReaderViewController.swift` in WP6 (behaviour-neutral refactor).
extension ReaderViewController {

    // MARK: - Lock state application

    /// Syncs `interactionLock` and the lock button's appearance to
    /// `AppSettings.isLocked` (FR-23…FR-26). Safe to call any number of
    /// times: locking when already locked, or unlocking when already
    /// unlocked, is a no-op inside `InteractionLock`.
    func applyLockState() {
        ink.writeDiagnostics("lock-toggle-before locked=\(AppSettings.isLocked)")
        defer {
            // Disabling/enabling scrolling can change the scroll view's insets
            // (nav-bar scroll-edge logic) without moving the offset; re-project.
            ink.setNeedsSync()
            DispatchQueue.main.async { [weak self] in self?.ink.writeDiagnostics("lock-toggle-after") }
        }
        if AppSettings.isLocked {
            if !interactionLock.isLocked {
                interactionLock.lock(pdfView)
            }
            lockButton.image = UIImage(systemName: "lock.fill")
            lockButton.tintColor = .systemOrange
        } else {
            interactionLock.unlock()
            lockButton.image = UIImage(systemName: "lock.open")
            lockButton.tintColor = nil
        }
    }
}
