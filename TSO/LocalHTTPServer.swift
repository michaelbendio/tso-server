import Foundation
import Network
import Combine

@MainActor
final class LocalHTTPServer: ObservableObject {
    @Published private(set) var startURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var htmlFileNames: [String] = []
    @Published private(set) var currentFileName: String?
    @Published private(set) var sourceFolderURL: URL?
    @Published private(set) var needsSourceFolderSelection = true

    private let resourceDirectoryName: String
    private let sourceFolderBookmarkKey = "TSOSourceFolderBookmark"
    private let runtimeDirectoryName = "ServedWWW"
    private var server: LoopbackHTTPServer?
    private var startTask: Task<Void, Never>?
    private var port: UInt16?
    private var reloadCounter = 0

    init(resourceDirectoryName: String) {
        self.resourceDirectoryName = resourceDirectoryName
        restoreBookmarkedSourceDirectory()
        refreshHTMLFileNames()
    }

    func setFolderSelectionError(_ error: Error) {
        errorMessage = "Unable to choose TSO folder: \(error.localizedDescription)"
    }

    func setSourceDirectory(_ url: URL) {
        do {
            let containsHTMLFiles = try withSecurityScopedAccess(to: url) {
                let containsHTMLFiles = try !htmlFiles(in: url).isEmpty
                if containsHTMLFiles {
                    try saveSourceDirectoryBookmark(for: url)
                }
                return containsHTMLFiles
            }

            guard containsHTMLFiles else {
                errorMessage = "The selected folder does not contain HTML files."
                return
            }

            sourceFolderURL = url
            needsSourceFolderSelection = false
            errorMessage = nil
            refreshHTMLFileNames()
            reloadCurrentFileIfNeeded()
        } catch {
            errorMessage = "Unable to use TSO folder: \(error.localizedDescription)"
        }
    }

    private func restoreBookmarkedSourceDirectory() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: sourceFolderBookmarkKey) else { return }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            let containsHTMLFiles = try withSecurityScopedAccess(to: url) {
                let containsHTMLFiles = try !htmlFiles(in: url).isEmpty
                if containsHTMLFiles && isStale {
                    try saveSourceDirectoryBookmark(for: url)
                }
                return containsHTMLFiles
            }

            guard containsHTMLFiles else {
                needsSourceFolderSelection = true
                errorMessage = "The remembered TSO folder does not contain HTML files."
                return
            }

            sourceFolderURL = url
            needsSourceFolderSelection = false
            errorMessage = nil
        } catch {
            needsSourceFolderSelection = true
            errorMessage = "Unable to restore TSO folder: \(error.localizedDescription)"
        }
    }

    private func saveSourceDirectoryBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: sourceFolderBookmarkKey)
    }

    private var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private func withSecurityScopedAccess<T>(to url: URL, _ work: () throws -> T) rethrows -> T {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try work()
    }

    func start(defaultFileName: String) async {
        if startURL != nil || startTask != nil { return }

        startTask = Task { [weak self] in
            guard let self else { return }

            do {
                guard let resourceURL = self.currentDocumentRootURL() else {
                    throw LocalHTTPServerError.missingResourceDirectory(resourceDirectoryName)
                }

                let resourceExists = FileManager.default.fileExists(atPath: resourceURL.path)
                guard resourceExists else {
                    throw LocalHTTPServerError.missingResourceDirectory(resourceDirectoryName)
                }

                let server = LoopbackHTTPServer(
                    documentRoot: resourceURL,
                    defaultFileName: defaultFileName
                )
                let port = try await server.start()

                await MainActor.run {
                    self.server = server
                    self.port = port
                    self.currentFileName = defaultFileName
                    self.startURL = self.url(for: defaultFileName, port: port)
                    self.startTask = nil
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Unable to start TSO: \(error.localizedDescription)"
                    self.startTask = nil
                }
            }
        }
    }

    func switchTo(fileName: String) {
        if startURL == nil {
            Task {
                await start(defaultFileName: fileName)
            }
            return
        }

        guard let port else { return }
        server?.setDefaultFileName(fileName)
        currentFileName = fileName
        startURL = url(for: fileName, port: port)
    }

    func refreshHTMLFileNames() {
        guard !needsSourceFolderSelection else {
            htmlFileNames = []
            return
        }

        guard let resourceURL = currentDocumentRootURL() else {
            htmlFileNames = []
            return
        }

        do {
            let contents = try htmlFiles(in: resourceURL)

            htmlFileNames = contents
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            htmlFileNames = []
        }
    }

    private func currentDocumentRootURL() -> URL? {
        try? rebuildRuntimeDocumentRoot()
        return runtimeDocumentRootURL()
    }

    private func rebuildRuntimeDocumentRoot() throws {
        let fileManager = FileManager.default
        guard let runtimeURL = runtimeDocumentRootURL() else { return }

        if fileManager.fileExists(atPath: runtimeURL.path) {
            try fileManager.removeItem(at: runtimeURL)
        }
        try fileManager.createDirectory(at: runtimeURL, withIntermediateDirectories: true)

        for sourceURL in sourceDirectoryURLs() {
            try withSecurityScopedAccess(to: sourceURL) {
                guard fileManager.fileExists(atPath: sourceURL.path) else { return }
                try copyDirectoryContents(from: sourceURL, to: runtimeURL)
            }
        }
    }

    private func runtimeDocumentRootURL() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(runtimeDirectoryName, isDirectory: true)
    }

    private func sourceDirectoryURLs() -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        if let bundledURL = Bundle.main.resourceURL?.appendingPathComponent(resourceDirectoryName, isDirectory: true) {
            urls.append(bundledURL)
        }

        if let sourceFolderURL {
            urls.append(sourceFolderURL)
            return urls
        }

        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(documentsURL)
        }

        return urls
    }

    private func copyDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        for itemURL in contents {
            let destinationItemURL = destinationURL.appendingPathComponent(itemURL.lastPathComponent)
            if fileManager.fileExists(atPath: destinationItemURL.path) {
                try fileManager.removeItem(at: destinationItemURL)
            }
            try fileManager.copyItem(at: itemURL, to: destinationItemURL)
        }
    }

    private func htmlFiles(in directoryURL: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
    }

    private func reloadCurrentFileIfNeeded() {
        guard let currentFileName, let port else { return }

        let nextFileName = htmlFileNames.contains(currentFileName)
            ? currentFileName
            : htmlFileNames.first

        guard let nextFileName else { return }

        server?.setDefaultFileName(nextFileName)
        self.currentFileName = nextFileName
        startURL = url(for: nextFileName, port: port)
    }

    private func url(for fileName: String, port: UInt16) -> URL? {
        reloadCounter += 1

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/" + fileName
        components.queryItems = [
            URLQueryItem(name: "reload", value: String(reloadCounter))
        ]
        return components.url
    }
}

private enum LocalHTTPServerError: LocalizedError {
    case missingResourceDirectory(String)

    var errorDescription: String? {
        switch self {
        case .missingResourceDirectory(let name):
            return "Bundled \(name) directory was not found."
        }
    }
}

private final class LoopbackHTTPServer {
    private let documentRoot: URL
    private var defaultFileName: String
    private let queue = DispatchQueue(label: "com.michael-bendio.TSO.loopback-http-server")
    private var listener: NWListener?

    init(documentRoot: URL, defaultFileName: String) {
        self.documentRoot = documentRoot
        self.defaultFileName = defaultFileName
    }

    func setDefaultFileName(_ defaultFileName: String) {
        queue.async {
            self.defaultFileName = defaultFileName
        }
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !didResume, let port = listener.port else { return }
                    didResume = true
                    continuation.resume(returning: port.rawValue)
                case .failed(let error):
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                self.receiveRequest(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
            guard error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let response = self.response(for: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for requestData: Data) -> Data {
        guard let requestText = String(data: requestData, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first else {
            return httpResponse(status: "400 Bad Request", body: Data("Bad Request".utf8), contentType: "text/plain; charset=utf-8")
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return httpResponse(status: "400 Bad Request", body: Data("Bad Request".utf8), contentType: "text/plain; charset=utf-8")
        }

        let method = String(requestParts[0])
        guard method == "GET" || method == "HEAD" else {
            return httpResponse(status: "405 Method Not Allowed", body: Data("Method Not Allowed".utf8), contentType: "text/plain; charset=utf-8")
        }

        let path = filePath(from: String(requestParts[1]))
        guard let fileURL = path.flatMap(resolveFileURL(path:)) else {
            return httpResponse(status: "404 Not Found", body: Data("Not Found".utf8), contentType: "text/plain; charset=utf-8")
        }

        do {
            let body = try Data(contentsOf: fileURL)
            return httpResponse(
                status: "200 OK",
                body: method == "HEAD" ? Data() : body,
                contentType: mimeType(for: fileURL.pathExtension),
                contentLength: body.count
            )
        } catch {
            return httpResponse(status: "500 Internal Server Error", body: Data("Internal Server Error".utf8), contentType: "text/plain; charset=utf-8")
        }
    }

    private func filePath(from rawTarget: String) -> String? {
        let target = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget
        let routedTarget = target == "/" ? "/\(defaultFileName)" : target

        guard let decoded = routedTarget.removingPercentEncoding else { return nil }

        let relative = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains("..") else {
            return nil
        }

        return relative
    }

    private func resolveFileURL(path: String) -> URL? {
        let root = documentRoot.standardizedFileURL
        let url = root.appendingPathComponent(path).standardizedFileURL

        guard url.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return url
    }

    private func httpResponse(status: String, body: Data, contentType: String, contentLength: Int? = nil) -> Data {
        var header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(contentLength ?? body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js":
            return "application/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "svg":
            return "image/svg+xml"
        case "pdf":
            return "application/pdf"
        case "zip":
            return "application/zip"
        default:
            return "application/octet-stream"
        }
    }
}
