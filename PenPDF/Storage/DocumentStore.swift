import CoreGraphics
import Foundation
import PencilKit
import os.log

/// Per-document persistence: the reading position (this package) and, later,
/// one `PKDrawing` per page (WP4).
///
/// SPEC §6.1: `<App Container>/Library/Application Support/PenPDF/Documents/<key>/`
/// SPEC §6.3: `meta.json` — position + a few document facts, written atomically
/// and debounced so a flurry of page-change/scroll events doesn't hammer disk.
final class DocumentStore {

    /// SPEC §6.3, exact shape. `formatVersion` lets us refuse to interpret a
    /// future/foreign layout rather than crash or misbehave; unknown versions
    /// are treated as "no saved position" (see `loadMeta`).
    struct Meta: Codable {
        struct Point: Codable {
            var x: Double
            var y: Double
        }

        var formatVersion: Int
        var displayName: String
        var pageCount: Int
        var lastPageIndex: Int
        var lastPoint: Point?
        var lastZoomRelativeToFit: Double?
        var updatedAt: Date

        static let currentFormatVersion = 1
    }

    private static let log = OSLog(subsystem: "com.georgebuhanov.penpdf", category: "DocumentStore")

    private let root: URL
    private var metaURL: URL { root.appending(path: "meta.json") }

    private var meta: Meta?
    private var metaDirty = false
    private var flushWork: DispatchWorkItem?

    /// Ink (WP4): in-memory cache of one `PKDrawing` per page, plus the set
    /// of pages that have changed since the last write. Drawings are vector
    /// data (small); keeping them all in memory for the Reader's lifetime is
    /// the sanctioned trade-off (SPEC §5.4 "Off-screen handling").
    private var drawings: [Int: PKDrawing] = [:]
    private var dirtyPages: Set<Int> = []
    private var inkFlushWork: DispatchWorkItem?

    /// Safety net (device finding 2026-09-16, four keys for one file): if
    /// this key has no folder yet but an existing folder describes the same
    /// document (same file name AND page count), adopt that folder instead
    /// of starting empty — losing every note is far worse than the remote
    /// chance of two different files sharing name and page count. The
    /// adoption is recorded in `aliases.json` so it stays stable.
    init(key: String, displayName: String, pageCount: Int) {
        let documents = URL.applicationSupportDirectory
            .appending(path: "PenPDF", directoryHint: .isDirectory)
            .appending(path: "Documents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let resolved = Self.resolveKey(key, displayName: displayName, pageCount: pageCount, in: documents)
        root = documents.appending(path: resolved, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static func resolveKey(_ key: String, displayName: String, pageCount: Int, in documents: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: documents.appending(path: key).path) { return key }
        let aliasesURL = documents.appending(path: "aliases.json")
        var aliases = (try? Data(contentsOf: aliasesURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        if let existing = aliases[key], fm.fileExists(atPath: documents.appending(path: existing).path) { return existing }

        // Look for a folder describing the same document; prefer the most recently updated.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var best: (key: String, updatedAt: Date)?
        for entry in (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? [] {
            let candidate = entry.lastPathComponent
            guard candidate != key, candidate.count == 64,
                  let data = try? Data(contentsOf: entry.appending(path: "meta.json")),
                  let meta = try? decoder.decode(Meta.self, from: data),
                  meta.displayName == displayName, meta.pageCount == pageCount
            else { continue }
            if best == nil || meta.updatedAt > best!.updatedAt { best = (candidate, meta.updatedAt) }
        }
        guard let adopted = best?.key else { return key }
        os_log("DocumentStore: adopting folder %{public}@ for new key %{public}@ (%{public}@, %d pages)",
               log: log, type: .error, String(adopted.prefix(8)), String(key.prefix(8)), displayName, pageCount)
        aliases[key] = adopted
        if let data = try? JSONEncoder().encode(aliases) { try? data.write(to: aliasesURL, options: .atomic) }
        return adopted
    }

    deinit {
        flushWork?.cancel()
        writeMetaIfDirty()
        inkFlushWork?.cancel()
        writeDirtyInk()
    }

    // MARK: - Position (WP3)

    /// Reads `meta.json` fresh from disk. Returns `nil` if it doesn't exist,
    /// can't be decoded, or was written by a format version we don't
    /// understand — all of which are legitimate "no saved position" cases
    /// (SPEC §8: "Missing meta.json → open at page 0").
    func loadMeta() -> Meta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(Meta.self, from: data) else {
            os_log("DocumentStore: meta.json failed to decode at %{public}@", log: Self.log, type: .error, root.path)
            return nil
        }
        guard decoded.formatVersion == Meta.currentFormatVersion else {
            os_log("DocumentStore: unknown formatVersion %d, ignoring saved position", log: Self.log, type: .error, decoded.formatVersion)
            return nil
        }
        return decoded
    }

    func savePosition(
        pageIndex: Int,
        point: CGPoint?,
        zoomRelativeToFit: Double?,
        displayName: String,
        pageCount: Int
    ) {
        var current = meta ?? loadMeta() ?? Meta(
            formatVersion: Meta.currentFormatVersion,
            displayName: displayName,
            pageCount: pageCount,
            lastPageIndex: pageIndex,
            lastPoint: nil,
            lastZoomRelativeToFit: nil,
            updatedAt: Date()
        )
        current.formatVersion = Meta.currentFormatVersion
        current.displayName = displayName
        current.pageCount = pageCount
        current.lastPageIndex = pageIndex
        current.lastPoint = point.map { Meta.Point(x: $0.x, y: $0.y) }
        current.lastZoomRelativeToFit = zoomRelativeToFit
        current.updatedAt = Date()
        meta = current
        metaDirty = true
        scheduleFlush()
    }

    /// Cancels any pending debounced write and writes immediately if dirty.
    /// Called from the Reader on resign-active, background, close, and deinit.
    func flush() {
        flushWork?.cancel()
        flushWork = nil
        writeMetaIfDirty()

        inkFlushWork?.cancel()
        inkFlushWork = nil
        writeDirtyInk()
    }

    // MARK: - Ink (WP4)

    /// Returns the drawing for a page, loading it from disk on first access
    /// and caching it thereafter. A page with no sidecar file (never drawn
    /// on, or ink erased down to nothing) is an empty `PKDrawing`.
    func drawing(forPage index: Int) -> PKDrawing {
        if let cached = drawings[index] { return cached }
        let loaded = (try? Data(contentsOf: inkURL(index)))
            .flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        drawings[index] = loaded
        return loaded
    }

    /// Records a page's current drawing and schedules a debounced write.
    /// Called on every stroke change and whenever a page's canvas is about
    /// to be recycled or the app is about to background (FR-20).
    func update(_ drawing: PKDrawing, forPage index: Int) {
        drawings[index] = drawing
        dirtyPages.insert(index)
        scheduleInkFlush()
    }

    // MARK: - Private

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeMetaIfDirty() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// FR-20: ink writes debounce at 1.5 s, separately from the 1 s position
    /// debounce above — strokes arrive far more often than page changes and
    /// each write is bigger, so they get their own timer.
    private func scheduleInkFlush() {
        inkFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeDirtyInk() }
        inkFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func writeMetaIfDirty() {
        guard metaDirty, let meta else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(meta) else {
            os_log("DocumentStore: failed to encode meta.json", log: Self.log, type: .error)
            return
        }
        do {
            try data.write(to: metaURL, options: .atomic)
            metaDirty = false
        } catch {
            os_log("DocumentStore: failed to write meta.json: %{public}@", log: Self.log, type: .error, String(describing: error))
            // Left dirty; the next flush() or debounced write will retry (§8).
        }
    }

    /// Writes every dirty page's drawing to its sidecar file, or deletes the
    /// file if the drawing is now empty (SPEC §6.1: "empty drawing ⇒ file
    /// deleted"). Failures are logged and the page stays dirty so the next
    /// flush retries (§8).
    private func writeDirtyInk() {
        guard !dirtyPages.isEmpty else { return }
        let fileManager = FileManager.default
        var stillDirty: Set<Int> = []
        for index in dirtyPages {
            guard let drawing = drawings[index] else { continue }
            let url = inkURL(index)
            if drawing.strokes.isEmpty {
                do {
                    try fileManager.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Already gone (never written, or removed by a prior flush) — fine.
                } catch {
                    os_log("DocumentStore: failed to remove %{public}@: %{public}@", log: Self.log, type: .error, url.lastPathComponent, String(describing: error))
                    stillDirty.insert(index)
                }
            } else {
                do {
                    try drawing.dataRepresentation().write(to: url, options: .atomic)
                } catch {
                    os_log("DocumentStore: failed to write %{public}@: %{public}@", log: Self.log, type: .error, url.lastPathComponent, String(describing: error))
                    stillDirty.insert(index)
                }
            }
        }
        dirtyPages = stillDirty
    }

    private func inkURL(_ index: Int) -> URL {
        root.appending(path: String(format: "page-%06d.drawing", index))
    }
}
