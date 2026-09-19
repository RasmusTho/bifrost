import SwiftUI
import YggdrasilCore

/// A16 lens: today's grouped attention log — the durable half of the
/// declared UI-only bend (item-level skip firehose stays UI-only; this
/// note's `overrides`/`counts`/`reasons` are the durable record).
struct AttentionLensView: View {
    let fileStore: VaultFileStore

    @State private var note: AttentionNote?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var lastRefreshedAt: Date?
    @State private var lastAction: AttentionOverride?

    private var relativePath: String { HeimdalPaths.attention(for: Date()) }

    var body: some View {
        YggLensScaffold(
            title: "Today",
            sourcePath: relativePath,
            isLoading: isLoading,
            loadError: loadError,
            lastRefreshedAt: lastRefreshedAt,
            onRetry: load
        ) {
                if let lastAction {
                    Section {
                        YggUndoBar(message: "Marked \(lastAction.overriddenDecision). Written to today's audit note.") {
                            undo(lastAction)
                        }
                        .listRowInsets(EdgeInsets(
                            top: YggTheme.Spacing.xs,
                            leading: 0,
                            bottom: YggTheme.Spacing.xs,
                            trailing: 0
                        ))
                        .listRowBackground(Color.clear)
                    }
                }

                Section("Today's overrides") {
                    if let overrides = note?.overrides, !overrides.isEmpty {
                        ForEach(overrides, id: \.overriddenAt) { override in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(override.itemId)
                                    .font(YggTheme.Typography.monospaceCaption)
                                    .foregroundStyle(YggTheme.Color.textPrimary)
                                Text("\(override.originalDecision) → \(override.overriddenDecision)")
                                    .font(YggTheme.Typography.caption)
                                    .foregroundStyle(YggTheme.Color.textSecondary)
                                if !override.note.isEmpty {
                                    Text(override.note).font(YggTheme.Typography.caption)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if override.overriddenDecision != "attended" {
                                    Button("Attend") { apply(override, decision: "attended") }
                                        .tint(YggTheme.Color.accent)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if override.overriddenDecision != "skipped" {
                                    Button("Skip") { apply(override, decision: "skipped") }
                                        .tint(YggTheme.Color.warning)
                                }
                            }
                        }
                    } else {
                        YggEmptyState(
                            systemImage: "arrow.left.arrow.right",
                            title: "Nothing new",
                            message: "Visible attention items can be swiped here when the live feed is available."
                        )
                        .listRowBackground(Color.clear)
                    }
                }
                Section("Counts") {
                    if let counts = note?.counts, !counts.isEmpty {
                        ForEach(counts, id: \.key) { entry in
                            HStack {
                                Text(entry.key)
                                    .font(YggTheme.Typography.monospaceCaption)
                                Spacer()
                                Text("\(entry.count)")
                                    .foregroundStyle(YggTheme.Color.textSecondary)
                                    .font(YggTheme.Typography.monospaceCaption)
                            }
                        }
                    } else {
                        Text("No attention activity recorded yet today.")
                            .foregroundStyle(YggTheme.Color.textSecondary)
                    }
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

    private func apply(_ existing: AttentionOverride, decision: String) {
        guard existing.overriddenDecision != decision else { return }
        appendOverride(
            AttentionOverride(
                itemId: existing.itemId,
                originalDecision: existing.overriddenDecision,
                overriddenDecision: decision,
                note: "you changed the attention decision",
                overriddenAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    private func undo(_ action: AttentionOverride) {
        appendOverride(
            AttentionOverride(
                itemId: action.itemId,
                originalDecision: action.overriddenDecision,
                overriddenDecision: action.originalDecision,
                note: "you undid the previous attention decision",
                overriddenAt: ISO8601DateFormatter().string(from: Date())
            ),
            clearsUndo: true
        )
    }

    private func appendOverride(_ override: AttentionOverride, clearsUndo: Bool = false) {
        do {
            try fileStore.readModifyWrite(relativePath) { document in
                var note = AttentionNote(document: document)
                note.addOverride(override)
                document = note.document
            }
            lastAction = clearsUndo ? nil : override
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
