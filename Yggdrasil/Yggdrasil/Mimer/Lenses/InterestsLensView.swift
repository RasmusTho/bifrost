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
    @State private var isLoading = true
    @State private var lastRefreshedAt: Date?
    @State private var undoNeverEntry: String?

    var body: some View {
        YggLensScaffold(
            title: "Interests",
            sourcePath: HeimdalPaths.interests,
            isLoading: isLoading,
            loadError: loadError,
            lastRefreshedAt: lastRefreshedAt,
            onRetry: load
        ) {
                Section("Interest weights") {
                    if weights.isEmpty {
                        YggEmptyState(
                            systemImage: "sparkles",
                            title: "No signal yet",
                            message: "Interest evidence will appear here as the vault is reviewed."
                        )
                        .listRowBackground(Color.clear)
                    }
                    ForEach(weights, id: \.name) { entry in
                        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
                            HStack {
                                Text(entry.name)
                                    .font(YggTheme.Typography.sectionHeader)
                                Spacer()
                                Text(String(format: "%.2f", entry.weight))
                                    .font(YggTheme.Typography.monospaceCaption)
                                    .foregroundStyle(YggTheme.Color.agent)
                            }
                            ProgressView(value: entry.weight)
                                .tint(YggTheme.Color.agent)
                            HStack {
                                Button("Less") { adjustWeight(entry, by: -0.1) }
                                Button("More") { adjustWeight(entry, by: 0.1) }
                                Spacer()
                                Button("Never", role: .destructive) { addToNever(entry.name) }
                            }
                            .font(YggTheme.Typography.caption.weight(.semibold))
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
                    if never.isEmpty {
                        Text("Nothing muted")
                            .font(YggTheme.Typography.caption)
                            .foregroundStyle(YggTheme.Color.textSecondary)
                    }
                    ForEach(never, id: \.self) { entry in
                        HStack {
                            Text(entry)
                                .font(YggTheme.Typography.body)
                            Spacer()
                            Button("Restore") { restoreFromNever(entry) }
                                .font(YggTheme.Typography.caption.weight(.semibold))
                                .tint(YggTheme.Color.accent)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let undoNeverEntry {
                    YggUndoBar(message: "Muted \(undoNeverEntry) in the vault.") {
                        restoreFromNever(undoNeverEntry)
                    }
                    .padding(.horizontal, YggTheme.Spacing.md)
                    .padding(.bottom, YggTheme.Spacing.sm)
                }
            }
            .onAppear(perform: load)
    }

    private func load() {
        isLoading = true
        defer {
            isLoading = false
            lastRefreshedAt = Date()
        }
        loadError = nil
        let results = fileStore.readMany([HeimdalPaths.interests, HeimdalPaths.watchlist, HeimdalPaths.never])
        func text(for path: String) throws -> String {
            try (results[path] ?? .failure(VaultFileStoreError.notFound(path))).get()
        }

        do {
            let interestsText = try text(for: HeimdalPaths.interests)
            let interests = InterestsNote(document: try FrontmatterDocument.parse(interestsText))
            weights = interests.weights
        } catch VaultFileStoreError.notFound {
            weights = []
        } catch {
            loadError = error.localizedDescription
        }

        do {
            let watchlistText = try text(for: HeimdalPaths.watchlist)
            watched = ListNote.watchlist(document: try FrontmatterDocument.parse(watchlistText)).entries
        } catch VaultFileStoreError.notFound {
            watched = []
        } catch {
            loadError = error.localizedDescription
        }

        do {
            let neverText = try text(for: HeimdalPaths.never)
            never = ListNote.never(document: try FrontmatterDocument.parse(neverText)).entries
        } catch VaultFileStoreError.notFound {
            never = []
        } catch {
            loadError = error.localizedDescription
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

    private func adjustWeight(_ entry: (name: String, weight: Double), by amount: Double) {
        setWeight(min(max(entry.weight + amount, 0), 1), for: entry.name)
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

    private func addToNever(_ entry: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        do {
            try fileStore.readModifyWrite(HeimdalPaths.never) { document in
                var note = ListNote.never(document: document)
                note.addEntry(
                    entry,
                    source: "mimer-iphone",
                    target: entry,
                    note: "muted from Interests lens",
                    timestamp: timestamp
                )
                document = note.document
            }
            undoNeverEntry = entry
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func restoreFromNever(_ entry: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        do {
            try fileStore.readModifyWrite(HeimdalPaths.never) { document in
                var note = ListNote.never(document: document)
                note.removeEntry(
                    entry,
                    source: "mimer-iphone",
                    target: entry,
                    note: "restored from Interests lens",
                    timestamp: timestamp
                )
                document = note.document
            }
            undoNeverEntry = nil
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
