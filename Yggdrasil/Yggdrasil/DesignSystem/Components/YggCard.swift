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

/// The shared native expression of a runtime-declared state. It carries no
/// authority of its own: callers choose a semantic state from durable client
/// evidence and this component renders it consistently.
struct YggStatus: View {
    enum Kind {
        case active, pending, healthy, destructive

        var color: SwiftUI.Color {
            switch self {
            case .active: YggTheme.Color.active
            case .pending: YggTheme.Color.warning
            case .healthy: YggTheme.Color.success
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
