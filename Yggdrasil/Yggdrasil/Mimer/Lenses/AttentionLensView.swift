import SwiftUI
import YggdrasilCore

/// A16 lens: today's grouped attention log — the durable half of the
/// declared UI-only bend (item-level skip firehose stays UI-only; this
/// note's `overrides`/`counts`/`reasons` are the durable record).
struct AttentionLensView: View {
    let fileStore: VaultFileStore

    @State private var note: AttentionNote?
    @State private var loadError: String?
    @State private var pendingItemId = ""
    @State private var pendingNote = ""

    private var relativePath: String { HeimdalPaths.attention(for: Date()) }

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
                Section("Today's Overrides") {
                    if let overrides = note?.overrides, !overrides.isEmpty {
                        ForEach(overrides, id: \.overriddenAt) { override in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(override.itemId).font(.body.weight(.medium))
                                Text("\(override.originalDecision) → \(override.overriddenDecision)")
                                    .font(YggTheme.Typography.caption)
                                    .foregroundStyle(YggTheme.Color.textSecondary)
                                if !override.note.isEmpty {
                                    Text(override.note).font(YggTheme.Typography.caption)
                                }
                            }
                        }
                    } else {
                        Text("No overrides recorded yet today.")
                            .foregroundStyle(YggTheme.Color.textSecondary)
                    }
                }
                Section("Counts") {
                    if let counts = note?.counts, !counts.isEmpty {
                        ForEach(counts, id: \.key) { entry in
                            HStack {
                                Text(entry.key)
                                Spacer()
                                Text("\(entry.count)").foregroundStyle(YggTheme.Color.textSecondary)
                            }
                        }
                    } else {
                        Text("No attention activity recorded yet today.")
                            .foregroundStyle(YggTheme.Color.textSecondary)
                    }
                }
                Section("Steer Attention") {
                    TextField("Item id", text: $pendingItemId)
                    TextField("Reason", text: $pendingNote)
                    Button("Mark Attended") { addOverride(decision: "attended") }
                        .disabled(pendingItemId.isEmpty)
                    Button("Mark Skipped") { addOverride(decision: "skipped") }
                        .disabled(pendingItemId.isEmpty)
                }
            }
            .navigationTitle("Today")
            .onAppear(perform: load)
        }
    }

    private func load() {
        do {
            let text = try fileStore.read(relativePath)
            note = AttentionNote(document: try FrontmatterDocument.parse(text))
            loadError = nil
        } catch VaultFileStoreError.notFound {
            note = AttentionNote(document: FrontmatterDocument(frontmatter: YAMLMap(), body: ""))
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func addOverride(decision: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        do {
            try fileStore.readModifyWrite(relativePath) { document in
                var note = AttentionNote(document: document)
                note.addOverride(AttentionOverride(
                    itemId: pendingItemId,
                    originalDecision: decision == "attended" ? "skipped" : "attended",
                    overriddenDecision: decision,
                    note: pendingNote,
                    overriddenAt: timestamp
                ))
                document = note.document
            }
            pendingItemId = ""
            pendingNote = ""
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
