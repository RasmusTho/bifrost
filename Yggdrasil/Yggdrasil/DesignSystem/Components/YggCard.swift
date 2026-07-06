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
        .background(YggTheme.Color.secondaryBackground)
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
        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
    }
}
