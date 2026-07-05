import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var server = LocalHTTPServer(resourceDirectoryName: "www")
    @State private var safariItem: SafariItem?
    @State private var isShowingFilePicker = false
    @State private var isShowingFolderPicker = false

    var body: some View {
        Group {
            if let url = server.startURL {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(server.currentFileName ?? url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)

                        Spacer()

                        Button("Choose Folder") {
                            isShowingFolderPicker = true
                        }
                        .buttonStyle(.bordered)

                        Button("Switch") {
                            server.refreshHTMLFileNames()
                            isShowingFilePicker = true
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
            } else if server.needsSourceFolderSelection {
                FolderSelectionView(
                    message: server.errorMessage,
                    onChooseFolder: {
                        isShowingFolderPicker = true
                    }
                )
            } else if let message = server.errorMessage {
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                HTMLFilePickerView(
                    title: "Choose TSO File",
                    fileNames: server.htmlFileNames,
                    currentFileName: server.currentFileName,
                    onChooseFolder: {
                        isShowingFolderPicker = true
                    }
                ) { fileName in
                    server.switchTo(fileName: fileName)
                }
            }
        }
        .sheet(isPresented: $isShowingFilePicker) {
            HTMLFilePickerView(
                title: "Switch TSO File",
                fileNames: server.htmlFileNames,
                currentFileName: server.currentFileName,
                onChooseFolder: {
                    isShowingFolderPicker = true
                }
            ) { fileName in
                server.switchTo(fileName: fileName)
                isShowingFilePicker = false
            }
            .presentationDetents([.medium, .large])
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
                    server.setSourceDirectory(url)
                }
            case .failure(let error):
                server.setFolderSelectionError(error)
            }
        }
        .onAppear {
            if server.needsSourceFolderSelection {
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
    let onChooseFolder: () -> Void
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
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Choose Folder", action: onChooseFolder)
                }
            }
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
