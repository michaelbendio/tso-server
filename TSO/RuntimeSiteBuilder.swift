import Foundation

struct RuntimeSiteSnapshot: Sendable, Equatable {
    let rootURL: URL
    let htmlFileNames: [String]
}

enum RuntimeSiteBuilderError: LocalizedError {
    case sourceDirectoryMissing
    case sourceFileMissing
    case unsupportedFileType
    case noHTMLFiles
    case symbolicLinkNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .sourceDirectoryMissing:
            "The selected TSO folder is unavailable. Make sure it remains downloaded in iCloud Drive."
        case .sourceFileMissing:
            "The selected HTML file is unavailable."
        case .unsupportedFileType:
            "Choose an HTML file (.html or .htm)."
        case .noHTMLFiles:
            "The selected folder does not contain HTML files."
        case .symbolicLinkNotAllowed(let name):
            "The selected folder contains an unsupported symbolic link: \(name)"
        }
    }
}

actor RuntimeSiteBuilder {
    private let fileManager: FileManager
    private let runtimeRootURL: URL

    init(
        fileManager: FileManager = .default,
        runtimeRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.runtimeRootURL = runtimeRootURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ServedWWW", isDirectory: true)
    }

    func build(from sourceURL: URL) throws -> RuntimeSiteSnapshot {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RuntimeSiteBuilderError.sourceDirectoryMissing
        }

        try rejectSymbolicLinks(in: sourceURL)

        let stagingURL = makeStagingURL()
        defer { try? fileManager.removeItem(at: stagingURL) }

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try copyDirectoryContents(from: sourceURL, to: stagingURL)

        let htmlFileNames = try htmlFileNames(in: stagingURL)
        guard !htmlFileNames.isEmpty else {
            throw RuntimeSiteBuilderError.noHTMLFiles
        }

        try installAtomically(stagingURL)
        return RuntimeSiteSnapshot(rootURL: runtimeRootURL, htmlFileNames: htmlFileNames)
    }

    func build(selectedHTMLFile sourceURL: URL) throws -> RuntimeSiteSnapshot {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw RuntimeSiteBuilderError.sourceFileMissing
        }

        guard ["html", "htm"].contains(sourceURL.pathExtension.lowercased()) else {
            throw RuntimeSiteBuilderError.unsupportedFileType
        }

        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let stagingURL = makeStagingURL()
        defer { try? fileManager.removeItem(at: stagingURL) }

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        // Copy sibling files too so a standalone HTML app can keep using relative
        // CSS, JavaScript, images, JSON, and other assets from its own directory.
        let contents = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for itemURL in contents {
            try Task.checkCancellation()
            try fileManager.copyItem(
                at: itemURL,
                to: stagingURL.appendingPathComponent(itemURL.lastPathComponent)
            )
        }

        try installAtomically(stagingURL)
        return RuntimeSiteSnapshot(rootURL: runtimeRootURL, htmlFileNames: [sourceURL.lastPathComponent])
    }

    private func makeStagingURL() -> URL {
        runtimeRootURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(runtimeRootURL.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
    }

    private func installAtomically(_ stagingURL: URL) throws {
        if fileManager.fileExists(atPath: runtimeRootURL.path) {
            _ = try fileManager.replaceItemAt(
                runtimeRootURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: runtimeRootURL)
        }
    }

    private func copyDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for itemURL in contents {
            try Task.checkCancellation()
            try fileManager.copyItem(
                at: itemURL,
                to: destinationURL.appendingPathComponent(itemURL.lastPathComponent)
            )
        }
    }

    private func rejectSymbolicLinks(in sourceURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw RuntimeSiteBuilderError.sourceDirectoryMissing
        }

        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw RuntimeSiteBuilderError.symbolicLinkNotAllowed(itemURL.lastPathComponent)
            }
        }
    }

    private func htmlFileNames(in directoryURL: URL) throws -> [String] {
        try fileManager
            .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
