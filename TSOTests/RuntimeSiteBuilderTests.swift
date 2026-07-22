import Foundation
import XCTest
@testable import TSO

final class RuntimeSiteBuilderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testBuildCopiesFilesAndSortsHTMLNames() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Source", isDirectory: true)
        let runtimeURL = temporaryDirectory.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data("B".utf8).write(to: sourceURL.appendingPathComponent("b.html"))
        try Data("A".utf8).write(to: sourceURL.appendingPathComponent("a.htm"))
        try Data("asset".utf8).write(to: sourceURL.appendingPathComponent("asset.js"))

        let builder = RuntimeSiteBuilder(runtimeRootURL: runtimeURL)
        let snapshot = try await builder.build(from: sourceURL)

        XCTAssertEqual(snapshot.htmlFileNames, ["a.htm", "b.html"])
        XCTAssertEqual(
            try String(contentsOf: runtimeURL.appendingPathComponent("asset.js"), encoding: .utf8),
            "asset"
        )
    }

    func testFailedBuildPreservesPreviouslyInstalledSite() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Source", isDirectory: true)
        let invalidSourceURL = temporaryDirectory.appendingPathComponent("Invalid", isDirectory: true)
        let runtimeURL = temporaryDirectory.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalidSourceURL, withIntermediateDirectories: true)
        try Data("working".utf8).write(to: sourceURL.appendingPathComponent("index.html"))
        try Data("not html".utf8).write(to: invalidSourceURL.appendingPathComponent("readme.txt"))

        let builder = RuntimeSiteBuilder(runtimeRootURL: runtimeURL)
        _ = try await builder.build(from: sourceURL)

        do {
            _ = try await builder.build(from: invalidSourceURL)
            XCTFail("Expected a folder without HTML to fail")
        } catch RuntimeSiteBuilderError.noHTMLFiles {
            // Expected.
        }

        XCTAssertEqual(
            try String(contentsOf: runtimeURL.appendingPathComponent("index.html"), encoding: .utf8),
            "working"
        )
    }

    func testBuildRejectsSymbolicLinks() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Source", isDirectory: true)
        let runtimeURL = temporaryDirectory.appendingPathComponent("Runtime", isDirectory: true)
        let outsideURL = temporaryDirectory.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data("page".utf8).write(to: sourceURL.appendingPathComponent("index.html"))
        try Data("secret".utf8).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: sourceURL.appendingPathComponent("outside.txt"),
            withDestinationURL: outsideURL
        )

        let builder = RuntimeSiteBuilder(runtimeRootURL: runtimeURL)
        do {
            _ = try await builder.build(from: sourceURL)
            XCTFail("Expected symbolic links to be rejected")
        } catch RuntimeSiteBuilderError.symbolicLinkNotAllowed(let name) {
            XCTAssertEqual(name, "outside.txt")
        }
    }
}
