import Foundation
import Network
import XCTest
@testable import TSO

final class LoopbackHTTPServerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var server: LoopbackHTTPServer!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: temporaryDirectory.appendingPathComponent("file name.html"))
        server = LoopbackHTTPServer(documentRoot: temporaryDirectory, defaultFileName: "file name.html")
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testServerAcceptsPreferredPortForPersistentWebStorageOrigin() {
        let server = LoopbackHTTPServer(
            documentRoot: temporaryDirectory,
            defaultFileName: "file name.html",
            preferredPort: 49_327
        )

        XCTAssertEqual(server.preferredPort, 49_327)
    }

    func testAddressInUseIsRecognizedForAutomaticPortFallback() {
        XCTAssertTrue(LoopbackHTTPServer.isAddressInUse(NWError.posix(.EADDRINUSE)))
        XCTAssertFalse(LoopbackHTTPServer.isAddressInUse(NWError.posix(.ECONNREFUSED)))
    }

    @MainActor
    func testSwitchReturnsToFileSelectionWithoutForgettingFolder() async throws {
        let suiteName = "TSOTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceFolderStore = SourceFolderStore(
            defaults: defaults,
            bookmarkKey: "SourceFolderBookmark"
        )
        let siteBuilder = RuntimeSiteBuilder(
            runtimeRootURL: temporaryDirectory.appendingPathComponent("Runtime", isDirectory: true)
        )
        let viewer = ViewerModel(
            sourceFolderStore: sourceFolderStore,
            siteBuilder: siteBuilder,
            defaults: defaults
        )

        viewer.setSourceDirectory(temporaryDirectory)
        while viewer.isRefreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        viewer.switchTo(fileName: "file name.html")
        while viewer.startURL == nil, viewer.errorMessage == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(viewer.startURL)

        viewer.showFileSelection()

        XCTAssertNil(viewer.startURL)
        XCTAssertEqual(viewer.sourceFolderURL, temporaryDirectory)
        XCTAssertFalse(viewer.needsSourceFolderSelection)
        XCTAssertEqual(viewer.htmlFileNames, ["file name.html"])
    }

    func testRootRoutesToDefaultFile() {
        let response = server.response(for: request("GET", "/"))

        XCTAssertTrue(header(of: response).hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(body(of: response), Data("hello".utf8))
    }

    func testPercentEncodedFileNameIsServed() {
        let response = server.response(for: request("GET", "/file%20name.html"))

        XCTAssertTrue(header(of: response).hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(body(of: response), Data("hello".utf8))
    }

    func testHeadReturnsContentLengthWithoutBody() {
        let response = server.response(for: request("HEAD", "/file%20name.html"))

        XCTAssertTrue(header(of: response).contains("Content-Length: 5"))
        XCTAssertTrue(body(of: response).isEmpty)
    }

    func testTraversalIsRejected() {
        let response = server.response(for: request("GET", "/../outside.txt"))

        XCTAssertTrue(header(of: response).hasPrefix("HTTP/1.1 404 Not Found"))
    }

    func testSymlinkEscapingDocumentRootIsRejected() throws {
        let outsideURL = temporaryDirectory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try Data("secret".utf8).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent("outside.txt"),
            withDestinationURL: outsideURL
        )

        let response = server.response(for: request("GET", "/outside.txt"))

        XCTAssertTrue(header(of: response).hasPrefix("HTTP/1.1 404 Not Found"))
    }

    private func request(_ method: String, _ path: String) -> Data {
        Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    }

    private func header(of response: Data) -> String {
        let parts = split(response)
        return String(decoding: parts.header, as: UTF8.self)
    }

    private func body(of response: Data) -> Data {
        split(response).body
    }

    private func split(_ response: Data) -> (header: Data, body: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else {
            return (response, Data())
        }
        return (response[..<range.lowerBound], response[range.upperBound...])
    }
}
