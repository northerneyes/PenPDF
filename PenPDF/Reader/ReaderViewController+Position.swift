import PDFKit
import UIKit

/// Position persistence (WP3): restore-on-open, debounced save-on-change,
/// and the page-change observation / title / button updates that ride along
/// with it. Split out of `ReaderViewController.swift` in WP6 (behaviour-
/// neutral refactor — see `deferred.md`).
extension ReaderViewController {

    // MARK: - Position (WP3)

    /// Minimum sane zoom relative to fit-width; matches the restore guard
    /// below. Anything outside this range is treated as corrupt/unset.
    static let zoomRange: ClosedRange<Double> = 0.2...8

    func restorePositionIfNeeded() {
        applyRestoredPosition()
    }

    /// Applies the saved page/point/zoom from `meta.json`, if any and if
    /// still valid.
    @discardableResult
    func applyRestoredPosition() -> Bool {
        guard let meta = store.loadMeta(),
              let page = pdfDocument.page(at: meta.lastPageIndex)
        else { return false }

        // WP6 (deferred.md "0.82"): only override autoScales' fit-width when
        // the owner deliberately zoomed IN. `autoScales` already re-fits on
        // every layout, so restoring a <=1.0 relative zoom just fights it and
        // can land short of full width after a resize.
        if let zoom = meta.lastZoomRelativeToFit, zoom.isFinite, zoom > 1.0, Self.zoomRange.contains(zoom) {
            pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * zoom
        }

        if let saved = meta.lastPoint {
            let point = CGPoint(x: saved.x, y: saved.y)
            if point.x.isFinite, point.y.isFinite,
               page.bounds(for: .cropBox).insetBy(dx: -8, dy: -8).contains(point) {
                pdfView.go(to: PDFDestination(page: page, at: point))
            } else {
                pdfView.go(to: page)
            }
        } else {
            pdfView.go(to: page)
        }
        return true
    }

    func savePosition() {
        // `resizePin != nil` → a resize is settling and the current page is
        // transient; saving it is how a rotation used to persist "page 12".
        guard hasRestoredPosition, resizePin == nil, let page = pdfView.currentPage else { return }

        let index = pdfDocument.index(for: page)
        guard index != NSNotFound else { return }

        var point: CGPoint?
        if let destination = pdfView.currentDestination,
           destination.page == page {
            let candidate = destination.point
            if candidate.x.isFinite, candidate.y.isFinite,
               page.bounds(for: .cropBox).insetBy(dx: -8, dy: -8).contains(candidate) {
                point = candidate
            }
        }

        var zoom: Double?
        let fit = pdfView.scaleFactorForSizeToFit
        if fit.isFinite, fit > 0 {
            let relative = Double(pdfView.scaleFactor / fit)
            if relative.isFinite, relative > 0 {
                zoom = relative
            }
        }

        store.savePosition(
            pageIndex: index,
            point: point,
            zoomRelativeToFit: zoom,
            displayName: fileURL.lastPathComponent,
            pageCount: pdfDocument.pageCount
        )
    }

    func flushEverything() {
        // WP4: pages still on screen never see `willEndDisplayingOverlayView`,
        // so their drawings must be pushed to the store explicitly before it
        // (and the position) are saved to disk.
        ink.pushLiveDrawingsToStore()
        savePosition()
        store.flush()
    }

    /// Same sanitization rule `applyRestoredPosition`/`savePosition` (WP3)
    /// apply to a saved point: `nil` unless finite and within the page's crop
    /// box (with an 8pt margin) — otherwise `go(to:)` should be given the
    /// page alone.
    func sanitizedPoint(_ point: CGPoint?, on page: PDFPage) -> CGPoint? {
        guard let point, point.x.isFinite, point.y.isFinite,
              page.bounds(for: .cropBox).insetBy(dx: -8, dy: -8).contains(point)
        else { return nil }
        return point
    }

    // MARK: - Page-change observation

    func startObservingPageChanges() {
        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            self?.updateTitle()
            self?.updatePageButtons()
            self?.savePosition()
        }
    }

    func updateTitle() {
        guard let currentPage = pdfView.currentPage else { return }
        let index = pdfDocument.index(for: currentPage)
        titleView.setCounter("\(index + 1) / \(pdfDocument.pageCount)")
    }

    func updatePageButtons() {
        previousPageButton.isEnabled = pdfView.canGoToPreviousPage
        nextPageButton.isEnabled = pdfView.canGoToNextPage
    }
}
