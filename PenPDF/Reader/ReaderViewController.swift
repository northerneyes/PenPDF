import PDFKit
import PencilKit
import UIKit

/// Hosts the PDFView, the §7 toolbar, and the position invariants (FR-10).
/// Ink (WP4), lock (WP5) and persistence (WP3) are stubbed with clearly
/// marked hooks; this package is only rendering + "never lose the page."
///
/// WP6: split into extensions (behaviour-neutral refactor; see
/// `ReaderViewController+Position.swift`, `+Resize.swift`, `+Lock.swift`,
/// `+Ink.swift`). Stored properties stay here; members those extensions
/// need are marked `// internal for extensions` below instead of `private`.
final class ReaderViewController: UIViewController {

    let fileURL: URL // internal for extensions (Position)
    let pdfDocument: PDFDocument // internal for extensions (Position)
    private let securityScoped: Bool

    let pdfView = PDFView()

    /// Per-document identity + position persistence (WP3), and ink (WP4)
    /// via the same instance.
    let store: DocumentStore // internal for extensions (Position)

    /// Gates page-change observation — see the comment in
    /// `viewDidLayoutSubviews` for why this must not start early.
    var hasRestoredPosition = false // internal for extensions (Position)
    var pageChangeObserver: NSObjectProtocol? // internal for extensions (Position)

    /// FR-31 / §7: the PDFKit-owned scroll view last handed to
    /// `setContentScrollView(_:for:.top)`. `weak` + identity comparison is
    /// the "did we already register this instance" flag (see
    /// `viewDidLayoutSubviews`).
    private weak var registeredContentScrollView: UIScrollView?
    private var resignActiveObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var scaleChangeObserver: NSObjectProtocol?

    // MARK: - Resize window (FR-10 / F1)

    /// Page (and sanitized point) captured when a rotation / Split View /
    /// window resize begins. Non-nil means "a resize is settling".
    ///
    /// PDFKit's `autoScales` re-layout is asynchronous and clamps the scroll
    /// offset (→ last page, or page 1) *after* the transition coordinator
    /// completes and even after the next run-loop turn, so a one-shot re-pin
    /// was never enough (that was F1). While this is set we re-pin on every
    /// signal PDFKit gives (scale change, layout pass, transition end) and
    /// suppress position saves so transient pages never reach `meta.json`.
    /// Cleared 0.4 s after the last signal. A second resize starting inside
    /// the window keeps the ORIGINAL pin — the page at that moment is garbage.
    var resizePin: (page: PDFPage, point: CGPoint?)? // internal for extensions (Resize, Position)
    var resizeWindowEnd: DispatchWorkItem? // internal for extensions (Resize)

    // MARK: - Ink (WP4)

    /// One tool picker per Reader; the single screen canvas observes it.
    private let toolPicker = PKToolPicker()
    let ink: ScreenInkController // internal for extensions (Position, Ink)

    /// S5: `ScreenCanvasView.undoManager` returns `nil`, so PencilKit never
    /// registers its own undo actions for it (the canvas holds a transient
    /// screen-space projection, not any one page's real drawing — see
    /// `ScreenCanvasView`). `ScreenInkController` registers explicit,
    /// page-scoped undo/redo against THIS manager instead, so the toolbar's
    /// Undo/Redo stay deterministic no matter which page was last drawn on.
    private let readerUndoManager = UndoManager()

    // MARK: - Lock (WP5)

    let interactionLock = InteractionLock() // internal for extensions (Lock)

    // MARK: - Title (WP5, FR-9)

    lazy var titleView = ReaderTitleView(name: fileURL.deletingPathExtension().lastPathComponent) // internal for extensions (Position)

    private lazy var filesButton = ReaderToolbar.filesItem(target: self, action: #selector(didTapFiles))
    lazy var lockButton = ReaderToolbar.lockItem(target: self, action: #selector(didTapLock)) // internal for extensions (Lock)
    lazy var previousPageButton = ReaderToolbar.previousPageItem(target: self, action: #selector(didTapPreviousPage)) // internal for extensions (Position)
    lazy var nextPageButton = ReaderToolbar.nextPageItem(target: self, action: #selector(didTapNextPage)) // internal for extensions (Position)
    private lazy var undoButton = ReaderToolbar.undoItem(target: self, action: #selector(didTapUndo))
    private lazy var redoButton = ReaderToolbar.redoItem(target: self, action: #selector(didTapRedo))
    private lazy var paletteButton = ReaderToolbar.paletteItem(target: self, action: #selector(didTapPalette))
    #if DEBUG
    lazy var debugInkToggleButton = ReaderToolbar.debugInkToggleItem(target: self, action: #selector(didTapDebugInkToggle)) // internal for extensions (Ink)
    #endif

    init(fileURL: URL, document: PDFDocument, securityScoped: Bool, identityKey: String) {
        self.fileURL = fileURL
        self.pdfDocument = document
        self.securityScoped = securityScoped
        let store = DocumentStore(key: identityKey, displayName: fileURL.lastPathComponent, pageCount: document.pageCount)
        self.store = store
        self.ink = ScreenInkController(
            pdfView: pdfView,
            document: document,
            store: store,
            toolPicker: toolPicker,
            undoManager: readerUndoManager
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let pageChangeObserver {
            NotificationCenter.default.removeObserver(pageChangeObserver)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let scaleChangeObserver {
            NotificationCenter.default.removeObserver(scaleChangeObserver)
        }
        resizeWindowEnd?.cancel()
        if securityScoped {
            fileURL.stopAccessingSecurityScopedResource()
        }
    }

    override func loadView() {
        view = ResponderView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            // FR-31 / §7: full-bleed under the glass bar — the document runs
            // beneath the system nav bar like Preview, so top/bottom pin to
            // the root view's edges, not the safe area. Leading/trailing stay
            // on the safe area (no horizontal bar to bleed under).
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // S5 (`spec/notes/S5-screen-canvas.md`): the ink canvas is attached
        // by `ScreenInkController` INSIDE PDFKit's scroll view (sibling of the
        // zoomed document view — never scaled, and every finger gesture still
        // reaches the scroll view's own pan/pinch as ancestors). Nothing to
        // add here; `ink.setNeedsSync()` below attaches on first layout.

        // §5.5, exact.
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = false
        pdfView.interpolationQuality = .high
        pdfView.backgroundColor = .secondarySystemBackground
        // S5: no `PDFPageOverlayViewProvider` and no markup-mode routing —
        // ink lives in `ink.canvas` inside PDFKit's scroll view and gets
        // Pencil input directly; PDFKit's own markup handling stays off.
        pdfView.isInMarkupMode = false
        pdfView.document = pdfDocument
        // S5: build the initial screen-space projection of the document's
        // ink now that `pdfView` has a document and a first layout is coming.
        ink.setNeedsSync()

        configureScrollViews(in: pdfView)

        navigationItem.leftBarButtonItem = filesButton
        // Rightmost item first: this reversed order is what UINavigationBar
        // needs to render the §7 left-to-right layout 🔒 ◁ ▷ ↶ ↷ ✎.
        var rightItems = [paletteButton, redoButton, undoButton, nextPageButton, previousPageButton, lockButton]
        #if DEBUG
        // Debug-only (FR-18a): the simulator has no Pencil and treats the
        // mouse as a finger (`anyInput`), so without this there is no way to
        // scroll a page without drawing on it. Compiled out of Release.
        rightItems.insert(debugInkToggleButton, at: 0)
        #endif
        navigationItem.rightBarButtonItems = rightItems
        navigationController?.navigationBar.prefersLargeTitles = false

        // FR-9 / §7: Preview-style titleView (thumbnail + name + live counter)
        // instead of the plain nav-bar title.
        navigationItem.titleView = titleView
        let document = pdfDocument
        DispatchQueue.global(qos: .userInitiated).async {
            let thumbnail = document.page(at: 0)?.thumbnail(of: CGSize(width: 66, height: 66), for: .cropBox)
            DispatchQueue.main.async { [weak self] in
                self?.titleView.setThumbnail(thumbnail)
            }
        }

        // WP5: apply the persisted lock setting once the toolbar exists so
        // the lock icon starts in the right state.
        applyLockState()

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.flushEverything() }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.flushEverything() }

        // FR-10 / F1: `autoScales` posts this when it picks a new scale after
        // a resize — the most reliable "PDFKit just re-laid out" signal we get.
        scaleChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // S5: the ink canvas is rendered at native screen resolution
            // regardless of PDF zoom (it's a sibling above `pdfView`, never
            // magnified by PDFKit's ancestor transform), so — unlike S2's
            // bitmap re-render — there is no blur to wait out. Re-sync every
            // frame; `ScreenInkController.setNeedsSync()` coalesces a pinch's
            // rapid-fire notifications into one sync per run-loop turn.
            self.ink.setNeedsSync()
            guard self.resizePin != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyResizePin()
                self?.scheduleResizeWindowEnd()
            }
        }

        #if DEBUG
        applyDebugInkState()
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // SPEC §5.4 step 6: show the palette and make the Reader's root view
        // first responder so PencilKit anchors the tool picker to it.
        ink.setPaletteVisible(true, for: view)
        view.becomeFirstResponder()
    }

    /// The toolbar's Undo/Redo buttons act on this manager directly
    /// (`didTapUndo`/`didTapRedo`); `ScreenInkController` was handed the same
    /// instance at init and registers its page-scoped undo actions there
    /// (see `readerUndoManager` above) — overriding the responder-chain
    /// property here just keeps this controller's own `UIResponder.undoManager`
    /// consistent with it.
    override var undoManager: UndoManager? { readerUndoManager }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // PDFKit may recreate its internal scroll view on layout; re-assert
        // this every time rather than once (§5.5 footnote, FR-10 / P3).
        configureScrollViews(in: pdfView)
        // S5: cheap and coalesced — catches any layout-driven page/zoom
        // change `.PDFViewScaleChanged`/`.PDFViewPageChanged` might not fire
        // for (e.g. a resize).
        ink.setNeedsSync()

        // FR-31 / §7: register PDFKit's own scroll view with the navigation
        // controller so it applies the scroll-edge glass effect (the bar
        // reacts as content passes under it). Done once, and again if
        // PDFKit ever swaps out its internal scroll view for a new instance
        // — `registeredContentScrollView` doubles as both the "already did
        // this" flag and the identity check.
        if let scrollView = firstScrollView(in: pdfView), scrollView !== registeredContentScrollView {
            setContentScrollView(scrollView, for: .top)
            registeredContentScrollView = scrollView
        }

        // WP5 / §5.7 step 4: PDFKit can add gesture recognizers/scroll views
        // lazily; re-apply lock to anything new every layout pass. No-op
        // unless currently locked.
        interactionLock.reapplyIfLocked(pdfView)

        // FR-10 / F1: while a resize is settling, correct any drift PDFKit's
        // asynchronous re-layout introduced — only when actually wrong, so we
        // never fight PDFKit on a layout pass that was already right.
        if let pin = resizePin, pdfView.currentPage !== pin.page {
            applyResizePin()
            scheduleResizeWindowEnd()
        }

        guard !hasRestoredPosition,
              pdfView.document != nil,
              view.bounds.width > 0,
              view.bounds.height > 0
        else { return }
        hasRestoredPosition = true

        // PDFKit posts a page-changed notification for page 0 during its
        // first layout pass. If we were already observing `.PDFViewPageChanged`
        // that notification would immediately overwrite the position we're
        // about to restore, landing the user on page 1 every single time
        // (SPEC §5.4 step 5 — the #1 way to break FR-13). So: restore first,
        // *then* start observing.
        restorePositionIfNeeded()
        startObservingPageChanges()
        updateTitle()
        updatePageButtons()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)

        // FR-10 / F1 (SPEC §5.4 "Rotation / resize"). Capture the page once,
        // at the start of the FIRST resize; see `resizePin` for why this is a
        // window rather than a one-shot re-pin. `currentDestination.point`
        // can be PDFKit's `kPDFDestinationUnspecifiedValue` garbage, and a
        // garbage point handed to `go(to:)` lands on the LAST page — so it is
        // sanitized or dropped (page-only pin).
        if resizePin == nil, hasRestoredPosition, let page = pdfView.currentPage {
            let destination = pdfView.currentDestination
            let point = (destination?.page == page) ? sanitizedPoint(destination?.point, on: page) : nil
            resizePin = (page, point)
        }

        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.applyResizePin()
            self?.scheduleResizeWindowEnd()
        }
    }

    // MARK: - Actions

    @objc private func didTapFiles() {
        flushEverything()
        dismiss(animated: true)
    }

    @objc private func didTapPreviousPage() {
        pdfView.goToPreviousPage(nil)
    }

    @objc private func didTapNextPage() {
        pdfView.goToNextPage(nil)
    }

    @objc private func didTapLock() {
        AppSettings.isLocked.toggle()
        applyLockState()
    }

    @objc private func didTapUndo() {
        readerUndoManager.undo()
    }

    @objc private func didTapRedo() {
        readerUndoManager.redo()
    }

    @objc private func didTapPalette() {
        // FR-18: exactly Preview's behaviour — show/hide the system palette.
        // Whether the Pencil draws is not affected.
        if !view.isFirstResponder {
            view.becomeFirstResponder()
        }
        ink.togglePalette(for: view)
    }

    // MARK: - P3 invariant / FR-31

    /// FR-10: tapping the status bar or nav bar must never scroll to page 1.
    /// UIScrollView's `scrollsToTop` is the iOS mechanism for that gesture,
    /// and PDFView is built from nested scroll views, so every one of them
    /// (recursively — PDFKit's internals aren't a single fixed view) needs
    /// it turned off.
    ///
    /// FR-31 / §7: also sets `contentInsetAdjustmentBehavior = .always` on
    /// each one so page 1 starts below the glass bar and the last page
    /// clears the home indicator, now that `pdfView` is pinned to `view`'s
    /// top/bottom edges instead of the safe area. S5: the ink canvas
    /// (`ink.canvas`, a `ScreenCanvasView`) is a SIBLING of `pdfView`, not a
    /// descendant of it anymore, so every scroll view this walk finds is
    /// genuinely PDFKit's own — no `PKCanvasView` exclusion needed (unlike
    /// pre-S5, where per-page canvases lived inside this very tree).
    ///
    /// FR-32 (two-finger pan) is currently reverted — see the comment in the
    /// body. Lock mode (§3.5) remains the
    /// total-immunity option.
    ///
    /// Called after `document` is set and again on every layout pass, since
    /// PDFKit can recreate its scroll view internals.
    private func configureScrollViews(in view: UIView) {
        if let scrollView = view as? UIScrollView {
            scrollView.scrollsToTop = false
            scrollView.contentInsetAdjustmentBehavior = .always
            // FR-32 (two-finger pan) reverted 2026-09-16 at the owner's
            // request: single-finger pan restored; palm handling is deferred
            // until writing is nailed. Lock mode remains the palm answer.
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
        }
        for subview in view.subviews {
            configureScrollViews(in: subview)
        }
    }

    /// FR-31 / §7: the first `UIScrollView` found under `pdfView` — PDFKit's
    /// own internal scroll view — for `setContentScrollView` registration.
    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
