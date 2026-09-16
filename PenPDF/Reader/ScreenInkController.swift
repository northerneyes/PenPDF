import PDFKit
import PencilKit
import UIKit
import os.log

/// Owns the single screen-scale `ScreenCanvasView` (spike S5,
/// `spec/notes/S5-screen-canvas.md`) and treats it as a pure VIEW over
/// `DocumentStore`'s per-page drawings — never as the source of truth.
///
/// Replaces `InkOverlayCoordinator` on this branch. The canvas sits as a
/// sibling above `pdfView` (never inside its transformed view tree — see
/// `ScreenCanvasView`'s header), so there is no PDFKit page-overlay
/// mechanism to bridge anymore: instead, this controller
/// - projects every visible page's stored `PKDrawing` into screen space and
///   assigns the union to `canvas.drawing` (`syncDisplay`), recomputed
///   whenever `pdfView` moves (`setNeedsSync`);
/// - watches PencilKit's delegate callbacks to know when a gesture starts
///   and ends, suppressing display re-sync while the pen is down so the
///   drawing in progress never visibly moves underneath the stroke;
/// - on pen-up, diffs what changed and commits it back into the correct
///   page(s) of the store, in page space, with explicit undo registration.
final class ScreenInkController: NSObject, PKCanvasViewDelegate {

    private static let log = OSLog(subsystem: "com.georgebuhanov.penpdf", category: "ScreenInkController")

    private let pdfView: PDFView
    private let document: PDFDocument
    private let store: DocumentStore
    private let toolPicker: PKToolPicker
    private let undoManager: UndoManager

    let canvas = ScreenCanvasView()

    // MARK: - Ink on/off (FR-18a)

    /// ON (the default, every launch, never persisted) makes the Pencil draw,
    /// like Apple Notes. OFF makes the Pencil behave exactly like a finger —
    /// Preview's markup button does the same thing — which in the simulator
    /// (mouse == finger, `anyInput`) is the only way to scroll a page without
    /// drawing on it.
    private(set) var isInkEnabled = true

    // MARK: - Gesture bracket / commit bookkeeping

    /// True from `didBeginUsingTool` to `didEndUsingTool`. While true,
    /// `syncDisplay()` is a no-op (design note "Scrolling while the pen is
    /// down") so the drawing in progress never visibly moves.
    private var penDown = false

    /// Set when `drawingDidChange` fires WHILE `penDown` — i.e. the model
    /// already changed mid-gesture (S2 finding: this happens for some tools
    /// before `didEndUsingTool`, and always for the eraser, which commits
    /// asynchronously). Read and cleared by `didEndUsingTool`.
    private var changedWhilePenDown = false

    /// Pen is up and `drawingDidChange` for the landing stroke/erase hasn't
    /// arrived yet. Cancelled the moment it does; otherwise fires after
    /// `idleFallbackDelay` and commits whatever is there (S2 "nothing
    /// changed" fallback — e.g. eraser tapped empty space, lasso tap-cancel).
    private var pendingCommitFallback: DispatchWorkItem?
    private static let idleFallbackDelay: TimeInterval = 0.25

    /// Guards against `canvasViewDrawingDidChange` reacting to our OWN
    /// assignment in `syncDisplay()` — assigning `canvas.drawing`
    /// programmatically fires the delegate exactly like a user stroke would
    /// (S2/S3 finding).
    private var isSyncingProgrammatically = false

    /// The stroke count `canvas.drawing` had immediately after the last
    /// `syncDisplay()`. For an inking-tool commit, everything beyond this
    /// index in `canvas.drawing.strokes` is new (PencilKit only appends for
    /// those tools); for eraser/lasso/anything else the whole canvas is
    /// rebuilt from scratch instead (see `commit()`).
    private var displayedStrokeCount = 0

    // MARK: - Sync coalescing

    private var syncScheduled = false
    private weak var observedScrollView: UIScrollView?
    private var contentOffsetObservation: NSKeyValueObservation?
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
        canvas.tool = toolPicker.selectedTool
        toolPicker.addObserver(canvas)

        // Self-sufficient triggers (design note "Coalescing"): the Reader
        // additionally calls `setNeedsSync()` from `viewDidLayoutSubviews`
        // and its own `.PDFViewScaleChanged` observer, which is harmless —
        // `setNeedsSync()` coalesces to one sync per run-loop turn.
        scaleChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: pdfView, queue: .main
        ) { [weak self] _ in self?.setNeedsSync() }
        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in self?.setNeedsSync() }
    }

    deinit {
        if let scaleChangeObserver { NotificationCenter.default.removeObserver(scaleChangeObserver) }
        if let pageChangeObserver { NotificationCenter.default.removeObserver(pageChangeObserver) }
        contentOffsetObservation?.invalidate()
        pendingCommitFallback?.cancel()
        toolPicker.removeObserver(canvas)
    }

    // MARK: - Coordinate model (S5 note "Coordinate model")

    /// Page space (unrotated PDF points, origin top-left, y DOWN — same
    /// convention the sidecar files were already written in by the retired
    /// per-page overlay canvases) → screen space (this canvas's/`pdfView`'s
    /// shared coordinate space).
    ///
    /// T = translate(page's top-left in view coordinates) ∘ scale(s, -s),
    /// where `s = pdfView.scaleFactor`.
    ///
    /// TODO (S5 note): only verified for `page.rotation == 0` — the project's
    /// 12-page test PDF has no rotated pages. A simple scale+translate cannot
    /// represent a 90°/270° rotation (that needs off-diagonal terms); the
    /// debug assertion below would catch the mismatch immediately on a
    /// rotated test PDF, but none was available to verify against.
    func pageTransform(_ page: PDFPage) -> CGAffineTransform? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let s = pdfView.scaleFactor
        guard s.isFinite, s > 0 else { return nil }

        let topLeftInView = pdfView.convert(CGPoint(x: bounds.minX, y: bounds.maxY), from: page)
        guard topLeftInView.x.isFinite, topLeftInView.y.isFinite else { return nil }

        // No Y flip: the sidecar/page space is already y-down with its origin
        // at the page's top-left (it is the coordinate space PDFKit gave the
        // old overlay canvases — a UIKit view), and PDFView's own coordinate
        // space is y-down too. Only PDFKit's *page* space is y-up, and that is
        // handled by asking `convert(_:from:)` for the top-left (minX, maxY).
        let transform = CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: topLeftInView.x, y: topLeftInView.y))

        // Numeric verification (S5 note, mandatory): transforming the page's
        // bottom-right corner in sidecar space must land within 0.5pt of what
        // PDFKit itself reports for that corner.
        let predictedBottomRight = CGPoint(x: bounds.width, y: bounds.height).applying(transform)
        let actualBottomRight = pdfView.convert(CGPoint(x: bounds.maxX, y: bounds.minY), from: page)
        let dx = abs(predictedBottomRight.x - actualBottomRight.x)
        let dy = abs(predictedBottomRight.y - actualBottomRight.y)
        assert(
            dx < 0.5 && dy < 0.5,
            "S5 pageTransform mismatch: predicted \(predictedBottomRight) actual \(actualBottomRight) (page.rotation=\(page.rotation))"
        )
        #if DEBUG
        let index = document.index(for: page)
        if index != NSNotFound, !Self.loggedTransformPages.contains(index) {
            Self.loggedTransformPages.insert(index)
            os_log(
                "S5 pageTransform verified: page %d predicted=(%.2f,%.2f) actual=(%.2f,%.2f) delta=(%.3f,%.3f) scale=%.4f rotation=%d",
                log: Self.log, type: .debug,
                index, predictedBottomRight.x, predictedBottomRight.y,
                actualBottomRight.x, actualBottomRight.y, dx, dy, s, page.rotation
            )
        }
        #endif

        return transform
    }

    #if DEBUG
    /// One-shot log gate for the numeric verification above, so it prints
    /// once per page (not on every `syncDisplay()`).
    private static var loggedTransformPages: Set<Int> = []
    #endif

    private var visiblePages: [PDFPage] { pdfView.visiblePages }

    // MARK: - Display sync (S5 note "Display")

    /// Rebuilds `canvas.drawing` as the union of every visible page's stored
    /// drawing, projected into screen space. A no-op while the pen is down
    /// (design note "Scrolling while the pen is down") — the pending sync
    /// lands right after the gesture's commit instead.
    func syncDisplay() {
        guard !penDown else { return }

        var strokes: [PKStroke] = []
        for page in visiblePages {
            let index = document.index(for: page)
            guard index != NSNotFound else { continue }
            let stored = store.drawing(forPage: index)
            guard !stored.strokes.isEmpty else { continue }
            guard let transform = pageTransform(page) else { continue }
            strokes.append(contentsOf: stored.transformed(using: transform).strokes)
        }

        isSyncingProgrammatically = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isSyncingProgrammatically = false
        displayedStrokeCount = strokes.count
    }

    /// Coalesces any number of triggers within one run-loop turn into a
    /// single `syncDisplay()` call (design note "Coalescing").
    func setNeedsSync() {
        ensureScrollObservation()
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncDisplay()
        }
    }

    /// (Re)locates PDFKit's own internal scroll view (the same walk the
    /// Reader uses for `setContentScrollView`) and KVO-observes its
    /// `contentOffset` so a one-finger/two-finger scroll re-syncs the
    /// display exactly like a zoom or page change does. PDFKit can recreate
    /// this scroll view, so the identity is rechecked on every call — cheap,
    /// since it only re-attaches when the instance actually changed.
    private func ensureScrollObservation() {
        guard let scrollView = Self.firstScrollView(in: pdfView), scrollView !== observedScrollView else { return }
        observedScrollView = scrollView
        contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.setNeedsSync()
        }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        penDown = true
        changedWhilePenDown = false
        pendingCommitFallback?.cancel()
        pendingCommitFallback = nil
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        penDown = false

        if changedWhilePenDown {
            // The model already changed during the gesture (S2 finding: the
            // eraser commits asynchronously and can beat `didEndUsingTool`).
            changedWhilePenDown = false
            commit()
            return
        }

        // Otherwise the landing change (if any) is still coming via
        // `drawingDidChange`; if it never arrives (nothing actually changed —
        // eraser on empty space, lasso tap-cancel), fall back after a short
        // delay so the display resumes normal syncing either way.
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, !self.penDown else { return }
            self.pendingCommitFallback = nil
            self.commit()
        }
        pendingCommitFallback?.cancel()
        pendingCommitFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleFallbackDelay, execute: fallback)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isSyncingProgrammatically else { return }

        if penDown {
            changedWhilePenDown = true
            return
        }

        // Pen is up: the just-finished stroke/erase landing, or an
        // undo/redo-from-toolbar change is impossible here (that path goes
        // through `applyPageDrawing`, not the canvas) — so this is always a
        // genuine gesture result.
        pendingCommitFallback?.cancel()
        pendingCommitFallback = nil
        commit()
    }

    // MARK: - Commit (S5 note "Commit rules")

    /// Commits whatever `canvas.drawing` holds beyond the last sync into the
    /// correct page(s) of the store, then re-syncs the display from the
    /// (now authoritative) store — the canvas never accumulates its own
    /// state; it is always re-derived.
    private func commit() {
        if canvas.tool is PKInkingTool {
            commitNewInkStrokes()
        } else {
            commitRebuildVisiblePages()
        }
        syncDisplay()
    }

    /// Inking tools (pen/marker/pencil/…) only ever APPEND strokes, so the
    /// cheap and correct move is to take everything beyond
    /// `displayedStrokeCount` as new, assign each new stroke to the page
    /// under its first point, and append it to that page's stored drawing.
    private func commitNewInkStrokes() {
        let allStrokes = canvas.drawing.strokes
        guard displayedStrokeCount <= allStrokes.count else {
            // Defensive: an inking tool should never leave fewer strokes than
            // last displayed. If it somehow does, fall back to a full rebuild
            // rather than slice a negative range.
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

        for (index, newPageStrokes) in strokesByPageIndex {
            guard let page = document.page(at: index), let transform = pageTransform(page) else { continue }
            let pageSpaceNew = PKDrawing(strokes: newPageStrokes).transformed(using: transform.inverted())
            let previous = store.drawing(forPage: index)
            let next = PKDrawing(strokes: previous.strokes + pageSpaceNew.strokes)
            registerUndo(pageIndex: index, previous: previous, next: next)
            store.update(next, forPage: index)
        }
    }

    /// Eraser / lasso / anything else: these can remove, split, or move
    /// strokes across pages (a lasso move can carry a stroke from one visible
    /// page to another), so the simplest correct rule is to rebuild every
    /// VISIBLE page's drawing from what the canvas currently shows, and
    /// persist only the pages that actually changed (design note "Commit
    /// rules").
    private func commitRebuildVisiblePages() {
        var strokesByPageIndex: [Int: [PKStroke]] = [:]
        for stroke in canvas.drawing.strokes {
            guard let pageIndex = pageIndex(forFirstPointOf: stroke) else { continue }
            strokesByPageIndex[pageIndex, default: []].append(stroke)
        }

        for page in visiblePages {
            let index = document.index(for: page)
            guard index != NSNotFound, let transform = pageTransform(page) else { continue }
            let canvasStrokes = strokesByPageIndex[index] ?? []
            let next = PKDrawing(strokes: canvasStrokes).transformed(using: transform.inverted())
            let previous = store.drawing(forPage: index)
            guard drawingsDiffer(previous, next) else { continue }
            registerUndo(pageIndex: index, previous: previous, next: next)
            // Pages that lost all their strokes get an empty drawing here,
            // which `DocumentStore.update` turns into a deleted sidecar file
            // on the next flush (SPEC §6.1).
            store.update(next, forPage: index)
        }
    }

    /// The page a stroke belongs to: whichever page is under its first
    /// point, in screen space (S5 note point 5 — "acceptable to assign the
    /// whole stroke to the page of its first point" for a stroke drawn
    /// across two visible pages).
    private func pageIndex(forFirstPointOf stroke: PKStroke) -> Int? {
        guard let localFirst = stroke.path.first?.location else { return nil }
        let screenPoint = localFirst.applying(stroke.transform)
        let pdfViewPoint = canvas.convert(screenPoint, to: pdfView)
        guard let page = pdfView.page(for: pdfViewPoint, nearest: true) else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    /// Cheap-first equality check: stroke count, then bounds (with a
    /// generous tolerance — re-derived transforms carry floating-point
    /// noise even when nothing actually changed), then, only if still
    /// ambiguous, the authoritative byte-for-byte comparison (design note
    /// "compare with previous (stroke count + bounds, then
    /// dataRepresentation)").
    private func drawingsDiffer(_ a: PKDrawing, _ b: PKDrawing) -> Bool {
        guard a.strokes.count == b.strokes.count else { return true }
        guard a.strokes.count > 0 else { return false }
        let boundsTolerance: CGFloat = 0.5
        let boundsDiffer = abs(a.bounds.minX - b.bounds.minX) > boundsTolerance
            || abs(a.bounds.minY - b.bounds.minY) > boundsTolerance
            || abs(a.bounds.maxX - b.bounds.maxX) > boundsTolerance
            || abs(a.bounds.maxY - b.bounds.maxY) > boundsTolerance
        if boundsDiffer { return true }
        return a.dataRepresentation() != b.dataRepresentation()
    }

    // MARK: - Undo (S5 note "Undo")

    private func registerUndo(pageIndex: Int, previous: PKDrawing, next: PKDrawing) {
        undoManager.registerUndo(withTarget: self) { controller in
            controller.applyPageDrawing(previous, pageIndex: pageIndex, redo: next)
        }
    }

    /// Applies a drawing to a page (undo or redo) and re-registers the
    /// opposite action, so repeated undo/redo round-trips indefinitely.
    private func applyPageDrawing(_ drawing: PKDrawing, pageIndex: Int, redo: PKDrawing) {
        undoManager.registerUndo(withTarget: self) { controller in
            controller.applyPageDrawing(redo, pageIndex: pageIndex, redo: drawing)
        }
        store.update(drawing, forPage: pageIndex)
        setNeedsSync()
    }

    // MARK: - Flush (SPEC §5.4 "Flush everything")

    /// Commits anything still pending from a just-finished gesture (the S2
    /// "nothing changed" fallback window) so ink is never lost on
    /// resign-active/background/close. If the pen is literally still down
    /// there is nothing safe to commit — `DocumentStore` already holds
    /// everything committed so far, and the in-progress stroke isn't lost so
    /// much as deferred (matches WP4's original flush contract, adapted:
    /// the store is already the truth here, this only closes the fallback
    /// window early).
    func pushLiveDrawingsToStore() {
        guard !penDown, pendingCommitFallback != nil else { return }
        pendingCommitFallback?.cancel()
        pendingCommitFallback = nil
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
