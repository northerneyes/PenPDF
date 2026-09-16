import CryptoKit
import Foundation

/// A stable identity for a PDF that does *not* depend on its path.
///
/// File URLs handed over by the Files app change when a document is renamed,
/// moved between folders, or evicted and re-downloaded by iCloud. Keying saved
/// state on the URL means silently losing your place. Instead we hash the file
/// size plus the head and tail of the bytes: ~1 ms, and immune to all of that.
enum DocumentIdentity {

    private static let chunkSize = 64 * 1024

    static func key(for url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return fallbackKey(for: url)
        }
        defer { try? handle.close() }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(size).littleEndian) { hasher.update(bufferPointer: $0) }

        if let head = try? handle.read(upToCount: chunkSize) {
            hasher.update(data: head)
        }
        if size > chunkSize * 2 {
            try? handle.seek(toOffset: UInt64(size - chunkSize))
            if let tail = try? handle.readToEnd() {
                hasher.update(data: tail)
            }
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
