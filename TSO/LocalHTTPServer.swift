import Foundation
import Network
import Combine

@MainActor
final class LocalHTTPServer: ObservableObject {
    @Published private(set) var startURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var htmlFileNames: [String] = []
    @Published private(set) var currentFileName: String?

    private let resourceDirectoryName: String
    private var server: LoopbackHTTPServer?
    private var startTask: Task<Void, Never>?
    private var port: UInt16?

    init(resourceDirectoryName: String) {
        self.resourceDirectoryName = resourceDirectoryName
        refreshHTMLFileNames()
    }

    func start(defaultFileName: String) async {
        if startURL != nil || startTask != nil { return }

        startTask = Task { [weak self] in
            guard let self else { return }

            do {
                guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(resourceDirectoryName, isDirectory: true) else {
                    throw LocalHTTPServerError.missingResourceDirectory(resourceDirectoryName)
                }

                let server = LoopbackHTTPServer(documentRoot: resourceURL, defaultFileName: defaultFileName)
                let port = try await server.start()

                await MainActor.run {
                    self.server = server
                    self.port = port
                    self.currentFileName = defaultFileName
                    self.startURL = URL(string: "http://127.0.0.1:\(port)/\(defaultFileName)")
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
        startURL = URL(string: "http://127.0.0.1:\(port)/\(fileName)")
    }

    func refreshHTMLFileNames() {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(resourceDirectoryName, isDirectory: true),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: nil
              ) else {
            htmlFileNames = []
            return
        }

        htmlFileNames = contents
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
