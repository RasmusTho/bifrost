import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Heimdal's isolated capture-client entry surface. It owns no Mimer lens
/// state and no vault writes; later capture slices extend this boundary.
struct HeimdalShellView: View {
    @StateObject private var folderManager = CaptureFolderManager()
    @StateObject private var sessionModel = CaptureSessionModel()
    @State private var isFolderPickerPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section("Capture Folder") {
                    if let folderURL = folderManager.boundFolderURL {
                        Label(folderURL.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .accessibilityIdentifier("heimdal.captureFolder.bound")
                    } else {
                        Label("No capture folder selected", systemImage: "folder.badge.questionmark")
                            .accessibilityIdentifier("heimdal.captureFolder.unbound")
                    }

                    Button("Choose Capture Folder") {
                        isFolderPickerPresented = true
                    }
                    .accessibilityIdentifier("heimdal.chooseCaptureFolder")

                    if let error = folderManager.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Capture") {
                    Button("Record") {}
                        .disabled(true)
                        .accessibilityIdentifier("heimdal.record.disabled")
                    Text("Recording becomes available in the next capture slice.")
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                }

                Section("Staged Items") {
                    if sessionModel.stagedItems.isEmpty {
                        Text("No staged recordings yet.")
                            .foregroundStyle(YggTheme.Color.textSecondary)
                    }
                }
            }
            .navigationTitle("Heimdal")
            .sheet(isPresented: $isFolderPickerPresented) {
                CaptureFolderPicker { url in
                    folderManager.bind(folderURL: url)
                    isFolderPickerPresented = false
                }
            }
        }
    }
}

struct CaptureFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
