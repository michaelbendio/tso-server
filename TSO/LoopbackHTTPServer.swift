import Foundation
import Network

enum LoopbackHTTPServerError: LocalizedError {
    case alreadyStarted
    case stoppedBeforeReady

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "The local TSO server is already running."
        case .stoppedBeforeReady:
            "The local TSO server stopped before it was ready."
        }
    }
}

final class LoopbackHTTPServer: @unchecked Sendable {
    private let documentRoot: URL
    let preferredPort: UInt16?
    private let queue = DispatchQueue(label: "com.michael-bendio.TSO.loopback-http-server")
    private var defaultFileName: String
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    init(documentRoot: URL, defaultFileName: String, preferredPort: UInt16? = nil) {
        self.documentRoot = documentRoot
        self.defaultFileName = defaultFileName
        self.preferredPort = preferredPort
    }

    deinit {
        listener?.cancel()
    }

    func setDefaultFileName(_ defaultFileName: String) {
        queue.async { [self] in
            self.defaultFileName = defaultFileName
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard listener == nil else {
                    continuation.resume(throwing: LoopbackHTTPServerError.alreadyStarted)
                    return
                }

                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(
                        host: .ipv4(.loopback),
                        port: preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
                    )

                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    startContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.handleListenerState(state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handle(connection)
                    }
                    listener.start(queue: queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func isAddressInUse(_ error: Error) -> Bool {
        guard let networkError = error as? NWError,
              case .posix(.EADDRINUSE) = networkError else {
            return false
        }
        return true
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            startContinuation?.resume(throwing: LoopbackHTTPServerError.stoppedBeforeReady)
            startContinuation = nil
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let continuation = startContinuation,
                  let port = listener?.port else { return }
            startContinuation = nil
            continuation.resume(returning: port.rawValue)
        case .failed(let error):
            guard let continuation = startContinuation else { return }
            startContinuation = nil
            continuation.resume(throwing: error)
        case .cancelled:
            guard let continuation = startContinuation else { return }
            startContinuation = nil
            continuation.resume(throwing: LoopbackHTTPServerError.stoppedBeforeReady)
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveRequest(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard error == nil, let data, !data.isEmpty, let self else {
                connection.cancel()
                return
            }

            let response = self.response(for: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func response(for requestData: Data) -> Data {
        guard let requestText = String(data: requestData, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first else {
            return errorResponse(status: "400 Bad Request", message: "Bad Request")
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return errorResponse(status: "400 Bad Request", message: "Bad Request")
        }

        let method = String(requestParts[0])
        guard method == "GET" || method == "HEAD" else {
            return errorResponse(status: "405 Method Not Allowed", message: "Method Not Allowed")
        }

        let path = filePath(from: String(requestParts[1]))
        guard let fileURL = path.flatMap(resolveFileURL(path:)) else {
            return errorResponse(status: "404 Not Found", message: "Not Found")
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let contentLength = attributes[.size] as? NSNumber else {
                return errorResponse(status: "500 Internal Server Error", message: "Internal Server Error")
            }
            let body = method == "HEAD" ? Data() : try Data(contentsOf: fileURL)
            return httpResponse(
                status: "200 OK",
                body: body,
                contentType: mimeType(for: fileURL.pathExtension),
                contentLength: contentLength.intValue
            )
        } catch {
            return errorResponse(status: "500 Internal Server Error", message: "Internal Server Error")
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
        let root = documentRoot.resolvingSymlinksInPath().standardizedFileURL
        let url = root
            .appendingPathComponent(path)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func errorResponse(status: String, message: String) -> Data {
        let body = Data(message.utf8)
        return httpResponse(status: status, body: body, contentType: "text/plain; charset=utf-8")
    }

    private func httpResponse(
        status: String,
        body: Data,
        contentType: String,
        contentLength: Int? = nil
    ) -> Data {
        let header = """
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
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js": "application/javascript; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "svg": "image/svg+xml"
        case "pdf": "application/pdf"
        case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }
}
