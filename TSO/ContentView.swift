import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewer = ViewerModel()
    @State private var safariItem: SafariItem?
    @State private var isShowingFolderPicker = false
    @State private var isShowingHTMLPicker = false

    private static let htmlType = UTType(filenameExtension: "html") ?? .data

    var body: some View {
        Group {
            if let url = viewer.startURL {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(viewer.currentFileName ?? url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)

                        Spacer()

                        if viewer.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button("Switch") {
                            viewer.showFileSelection()
                        }
                        .buttonStyle(.bordered)

                        Button("Files") {
                            isShowingHTMLPicker = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)

                    WebView(url: url) { externalURL in
                        safariItem = SafariItem(url: externalURL)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            } else if viewer.needsSourceFolderSelection {
                FolderSelectionView(
                    message: viewer.errorMessage,
                    onChooseFolder: {
                        isShowingFolderPicker = true
                    },
                    onOpenFile: {
                        isShowingHTMLPicker = true
                    }
                )
            } else if viewer.isRefreshing {
                ProgressView("Loading HTML files…")
            } else if let message = viewer.errorMessage {
                VStack(spacing: 16) {
                    Text(message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                    Button("Files") {
                        isShowingHTMLPicker = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                HTMLFilePickerView(
                    title: "Choose HTML",
                    fileNames: viewer.htmlFileNames,
                    currentFileName: viewer.currentFileName,
                    onSelect: { fileName in
                        viewer.switchTo(fileName: fileName)
                    },
                    onOpenFile: {
                        isShowingHTMLPicker = true
                    }
                )
            }
        }
        .sheet(item: $safariItem) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewer.setSourceDirectory(url)
                }
            case .failure(let error):
                viewer.setFolderSelectionError(error)
            }
        }
        .fileImporter(
            isPresented: $isShowingHTMLPicker,
            allowedContentTypes: [Self.htmlType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewer.openHTMLFile(url)
                }
            case .failure(let error):
                viewer.setFileSelectionError(error)
            }
        }
        .alert(
            "Server Error",
            isPresented: Binding(
                get: { viewer.startURL != nil && viewer.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewer.clearError()
                    }
                }
            )
        ) {
            Button("OK") {
                viewer.clearError()
            }
        } message: {
            Text(viewer.errorMessage ?? "An unknown error occurred.")
        }
        .onAppear {
            if viewer.needsSourceFolderSelection {
                isShowingFolderPicker = true
            }
        }
    }
}

private struct FolderSelectionView: View {
    let message: String?
    let onChooseFolder: () -> Void
    let onOpenFile: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Choose TSO Folder", systemImage: "folder")
        } description: {
            Text(message ?? "Choose the folder that contains your usual TSO HTML files, or open any HTML file with Files.")
        } actions: {
            Button("Choose TSO Folder", action: onChooseFolder)
                .buttonStyle(.borderedProminent)
            Button("Files", action: onOpenFile)
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

private struct HTMLFilePickerView: View {
    let title: String
    let fileNames: [String]
    let currentFileName: String?
    let onSelect: (String) -> Void
    let onOpenFile: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("TSO") {
                    if fileNames.isEmpty {
                        Text("No HTML files in the TSO folder")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(fileNames, id: \.self) { fileName in
                            Button {
                                onSelect(fileName)
                            } label: {
                                HStack {
                                    Text(fileName)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if fileName == currentFileName {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        onOpenFile()
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                } footer: {
                    Text("Open an HTML file anywhere available in the iPad Files picker.")
                }
            }
            .navigationTitle(title)
        }
    }
}

private struct SafariItem: Identifiable {
    let id = UUID()
    let url: URL
}

#Preview {
    ContentView()
}
