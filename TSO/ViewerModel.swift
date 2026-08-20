import Foundation
import Combine

@MainActor
final class ViewerModel: ObservableObject {
    @Published private(set) var startURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var htmlFileNames: [String] = []
    @Published private(set) var currentFileName: String?
    @Published private(set) var sourceFolderURL: URL?
    @Published private(set) var needsSourceFolderSelection = true
    @Published private(set) var isRefreshing = false

    private let sourceFolderStore: SourceFolderStore
    private let siteBuilder: RuntimeSiteBuilder
    private let defaults: UserDefaults
    private let loopbackPortKey = "TSOLoopbackHTTPPort"
    private var server: LoopbackHTTPServer?
    private var port: UInt16?
    private var runtimeRootURL: URL?
    private var refreshTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var reloadCounter = 0
    private var refreshID = UUID()

    init(
        sourceFolderStore: SourceFolderStore? = nil,
        siteBuilder: RuntimeSiteBuilder? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.sourceFolderStore = sourceFolderStore ?? SourceFolderStore()
        self.siteBuilder = siteBuilder ?? RuntimeSiteBuilder()
        self.defaults = defaults

        do {
            if let restoredURL = try self.sourceFolderStore.restore() {
                sourceFolderURL = restoredURL
                needsSourceFolderSelection = false
                refreshFiles()
            }
        } catch {
            errorMessage = "Unable to restore the TSO folder: \(error.localizedDescription)"
        }
    }

    deinit {
        refreshTask?.cancel()
        startTask?.cancel()
        server?.stop()
    }

    func setFolderSelectionError(_ error: Error) {
        errorMessage = "Unable to choose the TSO folder: \(error.localizedDescription)"
    }

    func clearError() {
        errorMessage = nil
    }

    func setSourceDirectory(_ url: URL) {
        loadFiles(from: url, rememberFolder: true)
    }

    func showFileSelection() {
        startURL = nil
        errorMessage = nil
        refreshFiles { [weak self] in
            self?.startURL = nil
        }
    }

    func refreshFiles(then completion: (() -> Void)? = nil) {
        guard let sourceFolderURL else {
            needsSourceFolderSelection = true
            return
        }
        loadFiles(from: sourceFolderURL, rememberFolder: false, completion: completion)
    }

    func switchTo(fileName: String) {
        guard htmlFileNames.contains(fileName) else {
            errorMessage = "The selected HTML file is no longer available."
            return
        }

        guard sourceFolderURL != nil else {
            needsSourceFolderSelection = true
            return
        }

        // A loopback listener can be invalidated while the app is suspended even
        // though this model still holds the server object. Starting a fresh listener
        // on an explicit file switch makes Switch a recovery path instead of reusing
        // a stale server that can only produce a blank web view.
        if let server {
            server.stop()
            self.server = nil
            port = nil
        }

        guard startTask == nil else { return }
        guard let runtimeRootURL else {
            errorMessage = "The TSO files have not finished loading."
            return
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (server, port) = try await startLoopbackServer(
                    documentRoot: runtimeRootURL,
                    defaultFileName: fileName
                )
                guard !Task.isCancelled else {
                    server.stop()
                    return
                }

                defaults.set(Int(port), forKey: loopbackPortKey)
                self.server = server
                self.port = port
                currentFileName = fileName
                startURL = servedURL(for: fileName, port: port)
                errorMessage = nil
            } catch {
                errorMessage = "Unable to start TSO: \(error.localizedDescription)"
            }
            startTask = nil
        }
    }

    private func startLoopbackServer(
        documentRoot: URL,
        defaultFileName: String
    ) async throws -> (LoopbackHTTPServer, UInt16) {
        let preferredPort = savedLoopbackPort()
        let preferredServer = LoopbackHTTPServer(
            documentRoot: documentRoot,
            defaultFileName: defaultFileName,
            preferredPort: preferredPort
        )

        do {
            return (preferredServer, try await preferredServer.start())
        } catch {
            guard preferredPort != nil,
                  LoopbackHTTPServer.isAddressInUse(error) else {
                throw error
            }

            preferredServer.stop()
            defaults.removeObject(forKey: loopbackPortKey)

            let fallbackServer = LoopbackHTTPServer(
                documentRoot: documentRoot,
                defaultFileName: defaultFileName
            )
            return (fallbackServer, try await fallbackServer.start())
        }
    }

    private func savedLoopbackPort() -> UInt16? {
        guard let value = defaults.object(forKey: loopbackPortKey) as? NSNumber,
              value.intValue > 0,
              value.intValue <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(value.intValue)
    }

    private func loadFiles(
        from url: URL,
        rememberFolder: Bool,
        completion: (() -> Void)? = nil
    ) {
        refreshTask?.cancel()
        refreshID = UUID()
        let requestID = refreshID
        isRefreshing = true

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await siteBuilder.build(from: url)
                guard !Task.isCancelled, refreshID == requestID else { return }

                var bookmarkWarning: String?
                if rememberFolder {
                    do {
                        try sourceFolderStore.save(url)
                    } catch {
                        bookmarkWarning = "The folder loaded, but it could not be remembered: \(error.localizedDescription)"
                    }
                }

                sourceFolderURL = url
                needsSourceFolderSelection = false
                apply(snapshot)
                errorMessage = bookmarkWarning
                completion?()
            } catch is CancellationError {
                // A newer refresh superseded this one.
            } catch {
                guard refreshID == requestID else { return }
                errorMessage = "Unable to load the TSO folder: \(error.localizedDescription)"
                if sourceFolderURL == nil {
                    needsSourceFolderSelection = true
                }
            }

            if refreshID == requestID {
                isRefreshing = false
                refreshTask = nil
            }
        }
    }

    private func apply(_ snapshot: RuntimeSiteSnapshot) {
        runtimeRootURL = snapshot.rootURL
        htmlFileNames = snapshot.htmlFileNames

        guard let port, let server else { return }
        let nextFileName = currentFileName.flatMap { snapshot.htmlFileNames.contains($0) ? $0 : nil }
            ?? snapshot.htmlFileNames.first
        guard let nextFileName else { return }

        server.setDefaultFileName(nextFileName)
        currentFileName = nextFileName
        startURL = servedURL(for: nextFileName, port: port)
    }

    private func servedURL(for fileName: String, port: UInt16) -> URL? {
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
