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
enum DocumentIdentity {

    private static let chunkSize = 64 * 1024
    private static let log = OSLog(subsystem: "com.georgebuhanov.penpdf", category: "DocumentIdentity")

    static func key(for url: URL) -> String {
        // Ref-counted: fine to call even if a caller higher up already holds access.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            os_log("DocumentIdentity: could not read file size for %{public}@, falling back to name hash",
                   log: log, type: .error, url.lastPathComponent)
            return fallbackKey(for: url)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            os_log("DocumentIdentity: could not open %{public}@, falling back to name hash",
                   log: log, type: .error, url.lastPathComponent)
            return fallbackKey(for: url)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(size).littleEndian) { hasher.update(bufferPointer: $0) }

        do {
            if let head = try handle.read(upToCount: min(chunkSize, size)) {
                hasher.update(data: head)
            }
            if size > chunkSize * 2 {
                try handle.seek(toOffset: UInt64(size - chunkSize))
                if let tail = try handle.read(upToCount: chunkSize) {
                    hasher.update(data: tail)
                }
            }
        } catch {
            os_log("DocumentIdentity: read failed for %{public}@ (%{public}@), falling back to name hash",
                   log: log, type: .error, url.lastPathComponent, String(describing: error))
            return fallbackKey(for: url)
        }

        return hexString(hasher.finalize())
    }

    private static func fallbackKey(for url: URL) -> String {
        hexString(SHA256.hash(data: Data(url.lastPathComponent.utf8)))
    }

    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
