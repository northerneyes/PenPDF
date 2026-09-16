import PDFKit
import PencilKit
import UIKit
import os.log

/// Owns the single screen-scale `ScreenCanvasView` (spike S5,
/// `spec/notes/S5-screen-canvas.md`) and treats it as a pure VIEW over
/// `DocumentStore`'s per-page drawings — never as the source of truth.
///
/// - The canvas is attached INSIDE PDFKit's scroll view (sibling of the zoomed
///   document view), framed over the visible rect, with its `contentOffset`
///   mirrored from the scroll view synchronously (KVO). Canvas content
///   coordinates therefore equal scroll-content ("document") coordinates:
///   ink is glued to the page during scrolling with no re-projection.
/// - Every visible page's stored `PKDrawing` is projected into document
///   coordinates and the union assigned to `canvas.drawing` (`syncDisplay`),
///   re-run when the zoom or the visible page set changes.
/// - PencilKit's delegate callbacks bracket a gesture; NOTHING touches
///   `canvas.drawing` while the pen is down (device findings 2026-09-16: any
///   programmatic assignment mid-stroke cancels the stroke in progress).
/// - On pen-up the change is committed back into the correct page(s) of the
///   store in page space, with explicit undo. The canvas is NOT re-assigned
///   afterwards — it already shows the result; only a sync that was deferred
///   during the gesture is applied.
/// - Tool widths are scaled by the PDF zoom so a pen is a page-space width,
///   like Preview: thick when zoomed in, consistent with stored ink.
final class ScreenInkController: NSObject, PKCanvasViewDelegate, PKToolPickerObserver {

    private static let log = OSLog(subsystem: "com.georgebuhanov.penpdf", category: "ScreenInkController")

    private let pdfView: PDFView
    private let document: PDFDocument
    private let store: DocumentStore
    private let toolPicker: PKToolPicker
    private let undoManager: UndoManager

    let canvas = ScreenCanvasView()

    // MARK: - Ink on/off (FR-18a)

    private(set) var isInkEnabled = true

    // MARK: - Gesture bracket / commit bookkeeping

    /// True from `didBeginUsingTool` to `didEndUsingTool`.
    private var penDown = false
    /// `drawingDidChange` fired while the pen was down (eraser commits
    /// asynchronously; some tools change the model before `didEndUsingTool`).
    private var changedWhilePenDown = false
    /// A sync was requested while the pen was down; applied after the
    /// gesture's commit.
    private var syncPendingAfterGesture = false
    /// Pen is up, no `drawingDidChange` yet. If none arrives (eraser on empty
    /// space, lasso tap), this only resumes syncing — it NEVER commits, since
    /// a commit against a not-yet-landed eraser change re-syncs stale state
    /// (device finding: "erases, then the strokes come back").
    private var pendingGestureEnd: DispatchWorkItem?
    private static let gestureEndFallbackDelay: TimeInterval = 0.25
    /// Our own `canvas.drawing` assignment fires `drawingDidChange` too.
    private var isSyncingProgrammatically = false
    /// Stroke count `canvas.drawing` had after the last sync/commit; for an
    /// inking tool everything beyond it is new.
    private var displayedStrokeCount = 0

    // MARK: - Attachment to PDFKit's scroll view

    private weak var hostScrollView: UIScrollView?
    private var contentOffsetObservation: NSKeyValueObservation?
    /// During a live pinch PDFKit scales its already-rendered document view
    /// with the scroll view's zoom transform and re-renders when it ends. The
    /// canvas mirrors that: while zooming it is scaled by the same factor
    /// about the content origin (momentarily soft, exactly like the page
    /// tiles), then re-projected crisp on the first sync after the gesture.
    /// Pure geometry — no per-frame re-projection, so nothing can jump.
    private var isMirroringZoom = false
    private var zoomStartScale: CGFloat = 1
    private var zoomStartOffset: CGPoint = .zero
    private var syncScheduled = false
    private var scaleChangeObserver: NSObjectProtocol?
    private var pageChangeObserver: NSObjectProtocol?

    init(
        pdfView: PDFView,
        document: PDFDocument,
        store: DocumentStore,
        toolPicker: PKToolPicker,
        undoManager: UndoManager
    ) {
        self.pdfView = pdfView
        self.document = document
        self.store = store
        self.toolPicker = toolPicker
        self.undoManager = undoManager
        super.init()

        canvas.delegate = self
        // The canvas is deliberately NOT a picker observer: the picker would
        // push unscaled tools straight into it. We observe instead and apply
        // zoom-scaled tools (see `applyScaledTool`).
        toolPicker.addObserver(self)
        applyScaledTool()

        scaleChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            self?.applyScaledTool()
            self?.setNeedsSync()
        }
        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in self?.setNeedsSync() }
    }

    deinit {
        if let scaleChangeObserver { NotificationCenter.default.removeObserver(scaleChangeObserver) }
        if let pageChangeObserver { NotificationCenter.default.removeObserver(pageChangeObserver) }
        contentOffsetObservation?.invalidate()
        pendingGestureEnd?.cancel()
        toolPicker.removeObserver(self)
    }

    // MARK: - Attachment (S5: canvas inside the scroll view)

    /// Attaches the canvas to PDFKit's internal scroll view (re-attaching if
    /// PDFKit recreates it) and mirrors `contentOffset` synchronously so the
    /// canvas always covers the visible rect with content coordinates equal
    /// to document coordinates. Cheap; safe to call on every layout pass.
    func attachIfNeeded() {
        guard let scrollView = Self.firstScrollView(in: pdfView) else { return }
        if scrollView !== hostScrollView {
            hostScrollView = scrollView
            canvas.removeFromSuperview()
            scrollView.addSubview(canvas)                 // last ⇒ above the document view
            scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(hostPinchChanged(_:)))
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                // Synchronous with the scroll: the frame/offset update lands
                // in the same run-loop turn as PDFKit's, before rendering.
                guard let self else { return }
                if self.isMirroringZoom {
                    // Still zooming (or zoom-bouncing): keep mirroring; end
                    // once the scroll view is neither.
                    if scrollView.isZooming || scrollView.isZoomBouncing {
                        self.mirrorZoom(scrollView)
                        return
                    }
                    self.endMirroringZoom()
                    return
                }
                self.followScrollView()
                self.setNeedsSync()                        // newly visible pages
            }
        }
        followScrollView()
    }

    @objc private func hostPinchChanged(_ recognizer: UIPinchGestureRecognizer) {
        guard let scrollView = hostScrollView else { return }
        switch recognizer.state {
        case .began:
            beginMirroringZoom(scrollView)
        case .changed:
            mirrorZoom(scrollView)
        default:
            break   // ending is detected in the KVO handler once the zoom bounce settles
        }
    }

    private func beginMirroringZoom(_ scrollView: UIScrollView) {
        guard !isMirroringZoom, !penDown else { return }
        isMirroringZoom = true
        zoomStartScale = scrollView.zoomScale
        zoomStartOffset = scrollView.contentOffset
        // Scale about the canvas's top-left so the maths below is a plain
        // similarity about the content origin.
        let layer = canvas.layer
        layer.anchorPoint = .zero
        layer.position = zoomStartOffset
        mirrorZoom(scrollView)
    }

    /// Canvas-local point L (drawn at start-zoom document coords L + o0)
    /// must land where the document view now shows it: k·(L + o0) − o(t).
    /// With anchor (0,0), transform scale(k) and position k·o0 that is exact.
    private func mirrorZoom(_ scrollView: UIScrollView) {
        guard isMirroringZoom, zoomStartScale > 0 else { return }
        let k = scrollView.zoomScale / zoomStartScale
        canvas.transform = CGAffineTransform(scaleX: k, y: k)
        canvas.layer.position = CGPoint(x: zoomStartOffset.x * k, y: zoomStartOffset.y * k)
    }

    private func endMirroringZoom() {
        guard isMirroringZoom else { return }
        isMirroringZoom = false
        canvas.transform = .identity
        canvas.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        followScrollView()
        setNeedsSync()                                     // crisp re-projection at the new zoom
    }

    private func followScrollView() {
        guard let scrollView = hostScrollView, !isMirroringZoom else { return }
        let offset = scrollView.contentOffset
        let size = scrollView.bounds.size
        let frame = CGRect(origin: offset, size: size)
        if canvas.frame != frame { canvas.frame = frame }
        // Content extent must contain everything we address; PencilKit may
        // grow it further, never shrink below this.
        let contentSize = CGSize(width: max(scrollView.contentSize.width, size.width),
                                 height: max(scrollView.contentSize.height, size.height))
        if canvas.contentSize != contentSize { canvas.contentSize = contentSize }
        if canvas.contentOffset != offset { canvas.contentOffset = offset }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, !(scrollView is PKCanvasView) { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Coordinate model (S5 note "Coordinate model")

    /// Page space (unrotated PDF points, origin top-left, y DOWN — the
    /// convention the sidecar files were written in by the retired per-page
    /// overlay canvases, which were UIKit views) → document coordinates
    /// (PDFKit's scroll-content space, y down). T = translate(page top-left
    /// in content space) ∘ scale(s, s), s = `pdfView.scaleFactor`. No Y flip:
    /// only PDFKit's *page* space is y-up, and `convert(_:from:)` absorbs it
    /// when asked for the top-left corner (minX, maxY).
    func pageTransform(_ page: PDFPage) -> CGAffineTransform? {
        guard let scrollView = hostScrollView else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let s = pdfView.scaleFactor
        guard s.isFinite, s > 0 else { return nil }

        let topLeftInView = pdfView.convert(CGPoint(x: bounds.minX, y: bounds.maxY), from: page)
        let topLeft = pdfView.convert(topLeftInView, to: scrollView)
        guard topLeft.x.isFinite, topLeft.y.isFinite else { return nil }

        let transform = CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: topLeft.x, y: topLeft.y))

        #if DEBUG
        // Geometry self-check: the page's bottom-right must agree with PDFKit.
        let predicted = CGPoint(x: bounds.width, y: bounds.height).applying(transform)
        let actualInView = pdfView.convert(CGPoint(x: bounds.maxX, y: bounds.minY), from: page)
        let actual = pdfView.convert(actualInView, to: scrollView)
        if abs(predicted.x - actual.x) > 0.5 || abs(predicted.y - actual.y) > 0.5 {
            os_log("S5 pageTransform mismatch: predicted (%.2f,%.2f) actual (%.2f,%.2f) rotation=%d",
                   log: Self.log, type: .error, predicted.x, predicted.y, actual.x, actual.y, page.rotation)
        }
        #endif
        return transform
    }

    private var visiblePages: [PDFPage] { pdfView.visiblePages }

    // MARK: - Display sync

    /// Rebuilds `canvas.drawing` as the union of every visible page's stored
    /// drawing in document coordinates. Deferred while the pen is down.
    func syncDisplay() {
        attachIfNeeded()
        guard !penDown else { syncPendingAfterGesture = true; return }
        guard !isMirroringZoom else { return }             // re-projected when the zoom ends

        var strokes: [PKStroke] = []
        for page in visiblePages {
            let index = document.index(for: page)
            guard index != NSNotFound else { continue }
            let stored = store.drawing(forPage: index)
            guard !stored.strokes.isEmpty, let transform = pageTransform(page) else { continue }
            strokes.append(contentsOf: stored.transformed(using: transform).strokes)
        }

        isSyncingProgrammatically = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isSyncingProgrammatically = false
        displayedStrokeCount = strokes.count
    }

    /// Coalesces any number of triggers within one run-loop turn.
    func setNeedsSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncDisplay()
        }
    }

    // MARK: - Tool scaling (Preview behaviour: widths are page-space)

    /// Applies the picker's current tool with its width multiplied by the PDF
    /// zoom, so a 3-pt pen is 3 page points — thick when zoomed in, and
    /// consistent with strokes already stored in page space (which are
    /// projected with the same factor). Also forwards ruler state.
    private func applyScaledTool() {
        let s = pdfView.scaleFactor
        let factor = (s.isFinite && s > 0) ? s : 1
        let tool = toolPicker.selectedTool
        if let inking = tool as? PKInkingTool {
            canvas.tool = PKInkingTool(inking.inkType, color: inking.color, width: inking.width * factor)
        } else if let eraser = tool as? PKEraserTool {
            canvas.tool = PKEraserTool(eraser.eraserType, width: eraser.width * factor)
        } else {
            canvas.tool = tool
        }
        canvas.isRulerActive = toolPicker.isRulerActive
    }

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) { applyScaledTool() }
    func toolPickerIsRulerActiveDidChange(_ toolPicker: PKToolPicker) { applyScaledTool() }
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {}
    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {}

    // MARK: - PKCanvasViewDelegate

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        penDown = true
        changedWhilePenDown = false
        pendingGestureEnd?.cancel()
        pendingGestureEnd = nil
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        penDown = false

        if changedWhilePenDown {
            changedWhilePenDown = false
            commit()
            return
        }

        // The landing change (if any) is still coming. If it never does,
        // just resume syncing — never commit speculatively.
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, !self.penDown else { return }
            self.pendingGestureEnd = nil
            self.applyPendingSyncIfNeeded()
        }
        pendingGestureEnd?.cancel()
        pendingGestureEnd = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gestureEndFallbackDelay, execute: fallback)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isSyncingProgrammatically else { return }
        if penDown {
            changedWhilePenDown = true
            return
        }
        pendingGestureEnd?.cancel()
        pendingGestureEnd = nil
        commit()
    }

    // MARK: - Commit (S5 note "Commit rules")

    /// Commits what `canvas.drawing` holds beyond the last sync into the
    /// store. The canvas is NOT re-assigned afterwards — it already shows the
    /// result (re-assigning is what raced the next stroke); only a deferred
    /// sync (scroll/zoom during the gesture) is applied.
    private func commit() {
        if canvas.tool is PKInkingTool {
            commitNewInkStrokes()
        } else {
            commitRebuildVisiblePages()
        }
        displayedStrokeCount = canvas.drawing.strokes.count
        applyPendingSyncIfNeeded()
    }

    private func applyPendingSyncIfNeeded() {
        guard syncPendingAfterGesture else { return }
        syncPendingAfterGesture = false
        syncDisplay()
    }

    /// Inking tools only APPEND strokes: everything beyond
    /// `displayedStrokeCount` is new; each goes to the page under its first
    /// point (S5 note point 5).
    private func commitNewInkStrokes() {
        let allStrokes = canvas.drawing.strokes
        guard displayedStrokeCount <= allStrokes.count else {
            commitRebuildVisiblePages()
            return
        }
        let newStrokes = Array(allStrokes[displayedStrokeCount...])
        guard !newStrokes.isEmpty else { return }

        var strokesByPageIndex: [Int: [PKStroke]] = [:]
        for stroke in newStrokes {
            guard let pageIndex = pageIndex(forFirstPointOf: stroke) else { continue }
            strokesByPageIndex[pageIndex, default: []].append(stroke)
        }
        for (index, pageStrokes) in strokesByPageIndex {
            guard let page = document.page(at: index), let transform = pageTransform(page) else { continue }
            let pageSpaceNew = PKDrawing(strokes: pageStrokes).transformed(using: transform.inverted())
            let previous = store.drawing(forPage: index)
            let next = PKDrawing(strokes: previous.strokes + pageSpaceNew.strokes)
            registerUndo(pageIndex: index, previous: previous, next: next)
            store.update(next, forPage: index)
        }
    }

    /// Eraser / lasso: rebuild every visible page's drawing from what the
    /// canvas shows; persist only pages that actually changed.
    private func commitRebuildVisiblePages() {
        var strokesByPageIndex: [Int: [PKStroke]] = [:]
        for stroke in canvas.drawing.strokes {
            guard let pageIndex = pageIndex(forFirstPointOf: stroke) else { continue }
            strokesByPageIndex[pageIndex, default: []].append(stroke)
        }
        for page in visiblePages {
            let index = document.index(for: page)
            guard index != NSNotFound, let transform = pageTransform(page) else { continue }
            let next = PKDrawing(strokes: strokesByPageIndex[index] ?? []).transformed(using: transform.inverted())
            let previous = store.drawing(forPage: index)
            guard drawingsDiffer(previous, next) else { continue }
            registerUndo(pageIndex: index, previous: previous, next: next)
            store.update(next, forPage: index)
        }
    }

    private func pageIndex(forFirstPointOf stroke: PKStroke) -> Int? {
        guard let localFirst = stroke.path.first?.location else { return nil }
        let contentPoint = localFirst.applying(stroke.transform)
        let pdfViewPoint = canvas.convert(contentPoint, to: pdfView)
        guard let page = pdfView.page(for: pdfViewPoint, nearest: true) else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    private func drawingsDiffer(_ a: PKDrawing, _ b: PKDrawing) -> Bool {
        guard a.strokes.count == b.strokes.count else { return true }
        guard a.strokes.count > 0 else { return false }
        let tolerance: CGFloat = 0.5
        if abs(a.bounds.minX - b.bounds.minX) > tolerance || abs(a.bounds.minY - b.bounds.minY) > tolerance
            || abs(a.bounds.maxX - b.bounds.maxX) > tolerance || abs(a.bounds.maxY - b.bounds.maxY) > tolerance {
            return true
        }
        return a.dataRepresentation() != b.dataRepresentation()
    }

    // MARK: - Undo

    private func registerUndo(pageIndex: Int, previous: PKDrawing, next: PKDrawing) {
        undoManager.registerUndo(withTarget: self) { controller in
            controller.applyPageDrawing(previous, pageIndex: pageIndex, redo: next)
        }
    }

    private func applyPageDrawing(_ drawing: PKDrawing, pageIndex: Int, redo: PKDrawing) {
        undoManager.registerUndo(withTarget: self) { controller in
            controller.applyPageDrawing(redo, pageIndex: pageIndex, redo: drawing)
        }
        store.update(drawing, forPage: pageIndex)
        setNeedsSync()
    }

    // MARK: - Flush (SPEC §5.4 "Flush everything")

    /// Commits anything uncommitted if the pen is up (idempotent when there
    /// is nothing new). An in-progress stroke is deferred, not lost.
    func pushLiveDrawingsToStore() {
        guard !penDown else { return }
        pendingGestureEnd?.cancel()
        pendingGestureEnd = nil
        commit()
    }

    // MARK: - Tool palette (FR-18)

    func togglePalette(for responder: UIResponder) {
        toolPicker.setVisible(!toolPicker.isVisible, forFirstResponder: responder)
    }

    func setPaletteVisible(_ visible: Bool, for responder: UIResponder) {
        toolPicker.setVisible(visible, forFirstResponder: responder)
    }

    // MARK: - Ink on/off (FR-18a)

    func setInkEnabled(_ enabled: Bool, for responder: UIResponder) {
        isInkEnabled = enabled
        canvas.isUserInteractionEnabled = enabled
        toolPicker.setVisible(enabled, forFirstResponder: responder)
    }
}
