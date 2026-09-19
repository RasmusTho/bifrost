import SwiftUI

/// A rounded content surface used by every lens for grouped content —
/// the one card style hosted clients reuse instead of styling their own.
struct YggCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
            content
        }
        .padding(YggTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YggTheme.Color.tertiaryBackground)
        .overlay {
            RoundedRectangle(cornerRadius: YggTheme.Radius.card, style: .continuous)
                .stroke(YggTheme.Color.divider, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.card, style: .continuous))
    }
}

struct YggSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(YggTheme.Typography.sectionHeader)
            if let subtitle {
                Text(subtitle)
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(YggTheme.Color.textSecondary)
            }
        }
    }
}

struct YggEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: YggTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(YggTheme.Color.textSecondary)
            Text(title)
                .font(YggTheme.Typography.sectionHeader)
            Text(message)
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(YggTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

struct YggPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(YggTheme.Typography.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, YggTheme.Spacing.sm)
        }
        .buttonStyle(.borderedProminent)
        .tint(YggTheme.Color.accent)
        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
    }
}

/// A compact semantic state marker. The caller supplies the state from
/// runtime evidence; this component has no authority of its own.
struct YggStatusPill: View {
    enum Kind {
        case neutral, agent, active, healthy, pending, destructive

        var color: SwiftUI.Color {
            switch self {
            case .neutral: YggTheme.Color.textSecondary
            case .agent: YggTheme.Color.agent
            case .active: YggTheme.Color.active
            case .healthy: YggTheme.Color.success
            case .pending: YggTheme.Color.warning
            case .destructive: YggTheme.Color.destructive
            }
        }
    }

    let title: String
    let systemImage: String
    let kind: Kind

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(YggTheme.Typography.caption.weight(.medium))
            .foregroundStyle(kind.color)
            .padding(.horizontal, YggTheme.Spacing.sm)
            .padding(.vertical, YggTheme.Spacing.xs)
            .background(kind.color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous)
                    .stroke(kind.color.opacity(0.45), lineWidth: 1)
            }
    }
}

struct YggBanner: View {
    let title: String
    let message: String
    let kind: YggStatusPill.Kind
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: YggTheme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
                Text(title)
                    .font(YggTheme.Typography.body.weight(.semibold))
                Text(message)
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(YggTheme.Color.textSecondary)
                if let retry {
                    Button("Retry", action: retry)
                        .font(YggTheme.Typography.caption.weight(.semibold))
                        .tint(YggTheme.Color.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(YggTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.10))
        .overlay {
            RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous)
                .stroke(kind.color.opacity(0.55), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
    }

    private var icon: String {
        switch kind {
        case .destructive: "xmark.octagon"
        case .pending: "exclamationmark.triangle"
        default: "info.circle"
        }
    }
}

struct YggUndoBar: View {
    let message: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: YggTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(YggTheme.Color.success)
            Text(message)
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textPrimary)
                .lineLimit(2)
            Spacer(minLength: YggTheme.Spacing.sm)
            Button("Undo", action: action)
                .font(YggTheme.Typography.caption.weight(.semibold))
                .tint(YggTheme.Color.accent)
        }
        .padding(.horizontal, YggTheme.Spacing.md)
        .padding(.vertical, YggTheme.Spacing.sm)
        .background(YggTheme.Color.overlay)
        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
    }
}

struct YggSourceFooter: View {
    let path: String
    var openAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: YggTheme.Spacing.xs) {
            Image(systemName: "doc.text")
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
                .accessibilityHidden(true)
            Text("Source:")
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
            Text(path)
                .font(YggTheme.Typography.monospaceCaption)
                .foregroundStyle(YggTheme.Color.textSecondary)
                .lineLimit(2)
            if let openAction {
                Button("Open in Obsidian ↗", action: openAction)
                    .font(YggTheme.Typography.caption.weight(.semibold))
                    .tint(YggTheme.Color.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct YggLoadingRows: View {
    var body: some View {
        ForEach(0..<3, id: \.self) { _ in
            VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
                RoundedRectangle(cornerRadius: YggTheme.Radius.control)
                    .fill(YggTheme.Color.tertiaryBackground)
                    .frame(height: 16)
                RoundedRectangle(cornerRadius: YggTheme.Radius.control)
                    .fill(YggTheme.Color.tertiaryBackground)
                    .frame(width: 180, height: 12)
            }
            .redacted(reason: .placeholder)
        }
    }
}

/// Shared load/empty/error/refresh language for the Mimer lenses. A lens is
/// a view over a markdown note, so the source stays visible even when the
/// live read is unavailable.
struct YggLensScaffold<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let title: String
    let sourcePath: String
    let isLoading: Bool
    let loadError: String?
    let lastRefreshedAt: Date?
    let onRetry: () -> Void
    let wrapsNavigationStack: Bool
    let content: Content

    init(
        title: String,
        sourcePath: String,
        isLoading: Bool,
        loadError: String?,
        lastRefreshedAt: Date?,
        onRetry: @escaping () -> Void,
        wrapsNavigationStack: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.sourcePath = sourcePath
        self.isLoading = isLoading
        self.loadError = loadError
        self.lastRefreshedAt = lastRefreshedAt
        self.onRetry = onRetry
        self.wrapsNavigationStack = wrapsNavigationStack
        self.content = content()
    }

    var body: some View {
        Group {
            // NavigationSplitView already provides stack navigation for each
            // column on iPad. A second stack here makes NavigationLink-based
            // detail views compete with the split view's own detail state;
            // after visiting Settings, the vault detail can then stop
            // responding to file selection. Phone tabs still need the local
            // stack supplied by this scaffold.
            if wrapsNavigationStack && horizontalSizeClass != .regular {
                NavigationStack { lensList }
            } else {
                lensList
            }
        }
    }

    private var lensList: some View {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(YggTheme.Typography.title)
                        Spacer()
                        if let lastRefreshedAt {
                            Text("refreshed \(lastRefreshedAt, style: .time)")
                                .font(YggTheme.Typography.monospaceCaption)
                                .foregroundStyle(YggTheme.Color.textSecondary)
                        }
                    }
                    .listRowBackground(Color.clear)

                    YggSourceFooter(path: sourcePath)
                        .listRowBackground(Color.clear)
                }

                if let loadError {
                    Section {
                        YggBanner(
                            title: "Vault unreachable",
                            message: loadError,
                            kind: .destructive,
                            retry: onRetry
                        )
                        .listRowInsets(EdgeInsets(
                            top: YggTheme.Spacing.xs,
                            leading: 0,
                            bottom: YggTheme.Spacing.xs,
                            trailing: 0
                        ))
                        .listRowBackground(Color.clear)
                    }
                }

                if isLoading {
                    Section {
                        YggLoadingRows()
                    }
                    .listRowBackground(Color.clear)
                } else {
                    content
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(YggTheme.Color.background)
            .navigationTitle(title)
            .tint(YggTheme.Color.accent)
            .refreshable {
                onRetry()
            }
    }
}
