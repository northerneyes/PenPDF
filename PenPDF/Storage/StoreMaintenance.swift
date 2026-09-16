import Foundation
import PencilKit
import os.log

/// Debug-only maintenance: merge per-document folders that describe the
/// same document (same file name + page count) into the most recently
/// updated one. Written after the 2026-09-16 identity incident (one file,
/// four keys). Triggered by launching with `--merge-duplicate-stores`;
/// originals are kept, renamed `<key>.merged-<timestamp>`, and a report is
/// written to `Documents/merge-report.txt` in the store root.
enum StoreMaintenance {

    private static let log = OSLog(subsystem: "com.georgebuhanov.penpdf", category: "StoreMaintenance")

    static func runIfRequested() {
        #if DEBUG
        guard CommandLine.arguments.contains("--merge-duplicate-stores") else { return }
        mergeDuplicates()
        #endif
    }

    static func mergeDuplicates() {
        let fm = FileManager.default
        let documents = URL.applicationSupportDirectory
            .appending(path: "PenPDF", directoryHint: .isDirectory)
            .appending(path: "Documents", directoryHint: .isDirectory)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var report: [String] = ["merge-duplicate-stores \(Date())"]

        struct Entry { let key: String; let url: URL; let meta: DocumentStore.Meta }
        var groups: [String: [Entry]] = [:]
        for url in (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? [] {
            let key = url.lastPathComponent
            guard key.count == 64,
                  let data = try? Data(contentsOf: url.appending(path: "meta.json")),
                  let meta = try? decoder.decode(DocumentStore.Meta.self, from: data)
            else { continue }
            groups["\(meta.displayName)|\(meta.pageCount)", default: []].append(Entry(key: key, url: url, meta: meta))
        }

        var aliases = (try? Data(contentsOf: documents.appending(path: "aliases.json")))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

        for (group, entries) in groups where entries.count > 1 {
            let sorted = entries.sorted { $0.meta.updatedAt > $1.meta.updatedAt }
            let target = sorted[0]
            report.append("\(group): target \(target.key.prefix(8)) (\(target.meta.updatedAt))")
            for other in sorted.dropFirst() {
                for file in (try? fm.contentsOfDirectory(at: other.url, includingPropertiesForKeys: nil)) ?? []
                    where file.pathExtension == "drawing" {
                    guard let data = try? Data(contentsOf: file), let incoming = try? PKDrawing(data: data) else { continue }
                    let targetFile = target.url.appending(path: file.lastPathComponent)
                    let existing = (try? Data(contentsOf: targetFile)).flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
                    let merged = existing.appending(incoming)
                    do {
                        try merged.dataRepresentation().write(to: targetFile, options: .atomic)
                        report.append("  \(file.lastPathComponent): \(existing.strokes.count) + \(incoming.strokes.count) from \(other.key.prefix(8)) → \(merged.strokes.count)")
                    } catch {
                        report.append("  \(file.lastPathComponent): WRITE FAILED \(error)")
                    }
                }
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = documents.appending(path: "\(other.key).merged-\(stamp)")
                try? fm.moveItem(at: other.url, to: backup)
                aliases[other.key] = target.key
                report.append("  \(other.key.prefix(8)) → backup \(backup.lastPathComponent)")
            }
        }
        if let data = try? JSONEncoder().encode(aliases) {
            try? data.write(to: documents.appending(path: "aliases.json"), options: .atomic)
        }
        let text = report.joined(separator: "\n")
        try? text.write(to: documents.appending(path: "merge-report.txt"), atomically: true, encoding: .utf8)
        os_log("%{public}@", log: log, type: .error, text)
    }
}
