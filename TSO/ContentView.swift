import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewer = ViewerModel()
    @State private var safariItem: SafariItem?
    @State private var isShowingFolderPicker = false

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
                    }
                )
            } else if viewer.isRefreshing {
                ProgressView("Loading TSO files…")
            } else if let message = viewer.errorMessage {
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                HTMLFilePickerView(
                    title: "Choose TSO File",
                    fileNames: viewer.htmlFileNames,
                    currentFileName: viewer.currentFileName
                ) { fileName in
                    viewer.switchTo(fileName: fileName)
                }
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
        .alert(
            "TSO Error",
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

    var body: some View {
        ContentUnavailableView {
            Label("Choose TSO Folder", systemImage: "folder")
        } description: {
            Text(message ?? "Choose the folder that contains the HTML files to serve.")
        } actions: {
            Button("Choose Folder", action: onChooseFolder)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct HTMLFilePickerView: View {
    let title: String
    let fileNames: [String]
    let currentFileName: String?
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if fileNames.isEmpty {
                    ContentUnavailableView(
                        "No HTML Files",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Add .html files to the selected TSO folder.")
                    )
                } else {
                    List(fileNames, id: \.self) { fileName in
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
