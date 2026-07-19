import SwiftUI
import YggdrasilCore

/// A18 lens: interest weights the human steers directly (`interests.md`),
/// plus the watchlist/never lists that shape what Heimdal watches.
struct InterestsLensView: View {
    let fileStore: VaultFileStore

    @State private var weights: [(name: String, weight: Double)] = []
    @State private var watched: [String] = []
    @State private var never: [String] = []
    @State private var newSource = ""
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                LensScaffold.errorBanner(loadError)
                Section("Interest Weights") {
                    if weights.isEmpty {
                        Text("No interest signal yet.").foregroundStyle(YggTheme.Color.textSecondary)
                    }
                    ForEach(weights, id: \.name) { entry in
                        HStack {
                            Text(entry.name)
                            Spacer()
                            Slider(
                                value: Binding(
                                    get: { entry.weight },
                                    set: { setWeight($0, for: entry.name) }
                                ),
                                in: 0...1
                            )
                            .frame(width: 140)
                        }
                    }
                }
                Section("Watching") {
                    ForEach(watched, id: \.self) { Text($0) }
                    HStack {
                        TextField("Add source to watch", text: $newSource)
                        Button("Watch") { addToWatchlist() }.disabled(newSource.isEmpty)
                    }
                }
                Section("Never") {
                    ForEach(never, id: \.self) { Text($0) }
                }
            }
            .navigationTitle("Interests")
            .onAppear(perform: load)
        }
    }

    private func load() {
        let paths = [
            HeimdalPaths.interests,
            HeimdalPaths.watchlist,
            HeimdalPaths.never
        ]
        loadError = nil
        Task { @MainActor in
            let results = await fileStore.readMany(paths)
            func text(for path: String) throws -> String {
                try (results[path] ?? .failure(VaultFileStoreError.notFound(path))).get()
            }

            do {
                let interestsText = try text(for: HeimdalPaths.interests)
                let interests = InterestsNote(document: try FrontmatterDocument.parse(interestsText))
                weights = interests.weights
            } catch VaultFileStoreError.notFound(_) {
                weights = []
            } catch {
                loadError = error.localizedDescription
            }

            do {
                let watchlistText = try text(for: HeimdalPaths.watchlist)
                watched = ListNote.watchlist(document: try FrontmatterDocument.parse(watchlistText)).entries
            } catch VaultFileStoreError.notFound(_) {
                watched = []
            } catch {
                loadError = error.localizedDescription
            }

            do {
                let neverText = try text(for: HeimdalPaths.never)
                never = ListNote.never(document: try FrontmatterDocument.parse(neverText)).entries
            } catch VaultFileStoreError.notFound(_) {
                never = []
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func setWeight(_ weight: Double, for name: String) {
        let path = HeimdalPaths.interests
        let selectedWeight = weight
        let interestName = name
        Task { @MainActor in
            do {
                try await fileStore.readModifyWrite(path) { document in
                    var note = InterestsNote(document: document)
                    note.setWeight(selectedWeight, for: interestName)
                    document = note.document
                }
                if let index = weights.firstIndex(where: { $0.name == interestName }) {
                    weights[index].weight = selectedWeight
                }
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func addToWatchlist() {
        let path = HeimdalPaths.watchlist
        let source = newSource
        let timestamp = ISO8601DateFormatter().string(from: Date())
        Task { @MainActor in
            do {
                try await fileStore.readModifyWrite(path) { document in
                    var note = ListNote.watchlist(document: document)
                    note.addEntry(
                        source,
                        source: "mimer-iphone",
                        target: source,
                        note: "added from Interests lens",
                        timestamp: timestamp
                    )
                    document = note.document
                }
                if newSource == source { newSource = "" }
                loadError = nil
                load()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
