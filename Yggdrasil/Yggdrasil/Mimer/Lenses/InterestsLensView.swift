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
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
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
        do {
            let interestsText = try fileStore.read(HeimdalPaths.interests)
            let interests = InterestsNote(document: try FrontmatterDocument.parse(interestsText))
            weights = interests.weights
        } catch VaultFileStoreError.notFound {
            weights = []
        } catch {
            loadError = error.localizedDescription
        }

        do {
            let watchlistText = try fileStore.read(HeimdalPaths.watchlist)
            watched = ListNote.watchlist(document: try FrontmatterDocument.parse(watchlistText)).entries
        } catch {
            watched = []
        }

        do {
            let neverText = try fileStore.read(HeimdalPaths.never)
            never = ListNote.never(document: try FrontmatterDocument.parse(neverText)).entries
        } catch {
            never = []
        }
    }

    private func setWeight(_ weight: Double, for name: String) {
        do {
            try fileStore.readModifyWrite(HeimdalPaths.interests) { document in
                var note = InterestsNote(document: document)
                note.setWeight(weight, for: name)
                document = note.document
            }
            if let index = weights.firstIndex(where: { $0.name == name }) {
                weights[index].weight = weight
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func addToWatchlist() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        do {
            try fileStore.readModifyWrite(HeimdalPaths.watchlist) { document in
                var note = ListNote.watchlist(document: document)
                note.addEntry(
                    newSource,
                    source: "mimer-iphone",
                    target: newSource,
                    note: "added from Interests lens",
                    timestamp: timestamp
                )
                document = note.document
            }
            newSource = ""
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
