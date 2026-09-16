import Foundation
import PencilKit

/// Per-document persistence: the reading position and one `PKDrawing` per page.
///
/// Ink lives in sidecar files rather than inside the PDF. Flattening strokes
/// into `PDFAnnotation`s on every change is slow and lossy; `PKDrawing` is
/// vector data that stays crisp at any zoom and round-trips perfectly.
final class DocumentStore {

    private let root: URL
    private let positionKey: String

    private var drawings: [Int: PKDrawing] = [:]
    private var dirtyPages: Set<Int> = []
    private var flushWork: DispatchWorkItem?

    init(key: String) {
        positionKey = "PenPDF.page.\(key)"
        root = URL.applicationSupportDirectory
            .appending(path: "Documents", directoryHint: .isDirectory)
            .appending(path: key, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        flushWork?.cancel()
        writeDirtyPages()
    }

    // MARK: - Reading position

    var lastPageIndex: Int? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: positionKey) != nil else { return nil }
            return defaults.integer(forKey: positionKey)
        }
        set {
            guard let newValue else { return }
            UserDefaults.standard.set(newValue, forKey: positionKey)
        }
    }

    // MARK: - Ink

    func drawing(forPage index: Int) -> PKDrawing {
        if let cached = drawings[index] { return cached }
        let loaded = (try? Data(contentsOf: inkURL(index)))
            .flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        drawings[index] = loaded
        return loaded
    }

    func update(_ drawing: PKDrawing, forPage index: Int) {
        drawings[index] = drawing
        dirtyPages.insert(index)
        scheduleFlush()
    }

    func flush() {
        flushWork?.cancel()
        flushWork = nil
        writeDirtyPages()
    }

    // MARK: - Private

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeDirtyPages() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func writeDirtyPages() {
        guard !dirtyPages.isEmpty else { return }
        let fileManager = FileManager.default
        for index in dirtyPages {
            guard let drawing = drawings[index] else { continue }
            let url = inkURL(index)
            if drawing.strokes.isEmpty {
                try? fileManager.removeItem(at: url)
            } else {
                try? drawing.dataRepresentation().write(to: url, options: .atomic)
            }
        }
        dirtyPages.removeAll()
    }

    private func inkURL(_ index: Int) -> URL {
        root.appending(path: String(format: "page-%06d.drawing", index))
    }
}
