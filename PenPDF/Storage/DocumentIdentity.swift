import CryptoKit
import Foundation
import os.log

/// A stable identity for a PDF that does *not* depend on its path.
///
/// File URLs handed over by the Files app change when a document is renamed,
/// moved between folders, or evicted and re-downloaded by iCloud. Keying saved
/// state on the URL means silently losing your place. Instead we hash the file
/// size plus the head and tail of the bytes: ~1 ms, and immune to all of that.
///
/// SPEC §6.2: hex(SHA256( UInt64(fileSize).littleEndian ∥ bytes[0..<min(64K,size)]
///            ∥ (size > 128K ? bytes[size-64K..<size] : ∅) ))
///
/// Device finding 2026-09-16: the same file received FOUR different keys in
/// one evening because the bytes were read while a file provider (iCloud /
/// Dropbox) was still materialising the file — short reads ⇒ different
/// hashes ⇒ "all my notes are gone". Hence: the read is *coordinated* (which
/// makes providers finish materialising first), every chunk is verified to be
/// complete, and there is NO fallback key — an unreadable file yields `nil`
/// and the caller refuses to open rather than inventing a new identity.
enum DocumentIdentity {

    private static let chunkSize = 64 * 1024
    private static let log = OSLog(subsystem: "com.georgebuhanov.penpdf", category: "DocumentIdentity")

    /// `nil` when the file could not be read *completely* right now.
    static func key(for url: URL) -> String? {
        // Ref-counted: fine to call even if a caller higher up already holds access.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Ask iCloud to fetch an evicted file; the coordinated read below
        // blocks until the provider has it (or errors).
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        var result: String?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = hash(readURL)
        }
        if let coordinationError {
            os_log("DocumentIdentity: coordinated read failed for %{public}@: %{public}@",
                   log: log, type: .error, url.lastPathComponent, coordinationError.localizedDescription)
        }
        if result == nil {
            os_log("DocumentIdentity: %{public}@ not fully readable — refusing to identify it",
                   log: log, type: .error, url.lastPathComponent)
        }
        return result
    }

    private static func hash(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(size).littleEndian) { hasher.update(bufferPointer: $0) }

        do {
            let headCount = min(chunkSize, size)
            guard let head = try handle.read(upToCount: headCount), head.count == headCount else { return nil }
            hasher.update(data: head)
            if size > chunkSize * 2 {
                try handle.seek(toOffset: UInt64(size - chunkSize))
                guard let tail = try handle.read(upToCount: chunkSize), tail.count == chunkSize else { return nil }
                hasher.update(data: tail)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
