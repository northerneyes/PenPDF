import Foundation

/// Remembers the most recently opened file so a cold launch lands back in it.
/// Stored as a bookmark, not a path, so it survives renames and iCloud moves.
enum LastDocument {

    private static let key = "PenPDF.lastDocumentBookmark"

    /// Call while the security-scoped resource is being accessed.
    static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            forget()
            return nil
        }
        return url
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
