import Foundation

@MainActor
final class SourceFolderStore {
    private let defaults: UserDefaults
    private let bookmarkKey: String

    init(
        defaults: UserDefaults = .standard,
        bookmarkKey: String = "TSOSourceFolderBookmark"
    ) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
    }

    func restore() throws -> URL? {
        guard let bookmarkData = defaults.data(forKey: bookmarkKey) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            try save(url)
        }
        return url
    }

    func save(_ url: URL) throws {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmarkData = try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmarkData, forKey: bookmarkKey)
    }

    func clear() {
        defaults.removeObject(forKey: bookmarkKey)
    }

    private var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        // Directory URLs returned by UIDocumentPickerViewController must be
        // persisted as minimal bookmarks on iOS/iPadOS. A full bookmark can
        // retain a transient UserFS file-provider identifier that no longer
        // resolves after the app relaunches.
        [.minimalBookmark]
        #endif
    }

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
}
