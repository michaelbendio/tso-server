import SwiftUI
import WebKit
import UIKit

struct WebView: UIViewRepresentable {
    let url: URL
    let onOpenExternalURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        fileprivate var parent: WebView
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]
        private var exportDirectoriesByPicker: [ObjectIdentifier: URL] = [:]

        init(parent: WebView) {
            self.parent = parent
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // iPadOS may reclaim WebKit's separate content process while the
            // containing app remains alive. Reload the current requested page
            // so a new content process is created instead of leaving a blank view.
            webView.load(URLRequest(url: parent.url))
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let requestURL = navigationAction.request.url {
                if shouldOpenExternally(requestURL) {
                    parent.onOpenExternalURL(requestURL)
                    return nil
                }

                webView.load(URLRequest(url: requestURL))
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let requestURL = navigationAction.request.url,
               shouldOpenExternally(requestURL) {
                parent.onOpenExternalURL(requestURL)
                decisionHandler(.cancel)
                return
            }

            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }

            if navigationAction.targetFrame == nil,
               let requestURL = navigationAction.request.url {
                webView.load(URLRequest(url: requestURL))
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        private func shouldOpenExternally(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased() else {
                return false
            }

            return host != "127.0.0.1" && host != "localhost"
        }
    }
}

@MainActor
extension WebView.Coordinator: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(sanitizedDownloadFileName(suggestedFilename))

        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            downloadDestinations[ObjectIdentifier(download)] = destinationURL
            completionHandler(destinationURL)
        } catch {
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }

        DispatchQueue.main.async {
            self.presentDocumentPicker(for: fileURL)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let fileURL = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }

    private func sanitizedDownloadFileName(_ suggestedFilename: String) -> String {
        let fallbackName = "resource-package.json"
        let trimmedName = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = trimmedName.isEmpty ? fallbackName : trimmedName
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")

        return fileName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
    }

    private func presentDocumentPicker(for fileURL: URL) {
        guard let presenter = topViewController() else {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            return
        }

        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        exportDirectoriesByPicker[ObjectIdentifier(picker)] = fileURL.deletingLastPathComponent()
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

@MainActor
extension WebView.Coordinator: UIDocumentPickerDelegate {
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        removeExportedTemporaryFiles(from: controller)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        removeExportedTemporaryFiles(from: controller)
    }

    private func removeExportedTemporaryFiles(from controller: UIDocumentPickerViewController) {
        if let directoryURL = exportDirectoriesByPicker.removeValue(forKey: ObjectIdentifier(controller)) {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }
}
