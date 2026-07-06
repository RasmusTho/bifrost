import SwiftUI
import YggdrasilCore

/// Renders a `MarkdownBlock` list as native SwiftUI views. Inline styling
/// (`**bold**`, `` `code` ``, links) rides on `Text(LocalizedStringKey:)`,
/// which already understands that subset — this view only lays out block
/// structure (headings, lists, quotes, code, rules, paragraphs).
struct MarkdownRendererView: View {
    let blocks: [MarkdownBlock]

    init(text: String) {
        self.blocks = MarkdownDocument.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineStyled(text))
                .font(headingFont(for: level))
                .padding(.top, level <= 2 ? YggTheme.Spacing.sm : 0)
        case .paragraph(let text):
            Text(inlineStyled(text))
                .font(YggTheme.Typography.body)
        case .bulletItem(let text, let indent):
            HStack(alignment: .top, spacing: YggTheme.Spacing.xs) {
                Text("•")
                Text(inlineStyled(text))
                    .font(YggTheme.Typography.body)
            }
            .padding(.leading, CGFloat(indent) * YggTheme.Spacing.md)
        case .numberedItem(let number, let text, let indent):
            HStack(alignment: .top, spacing: YggTheme.Spacing.xs) {
                Text("\(number).")
                Text(inlineStyled(text))
                    .font(YggTheme.Typography.body)
            }
            .padding(.leading, CGFloat(indent) * YggTheme.Spacing.md)
        case .blockquote(let text):
            HStack(spacing: YggTheme.Spacing.sm) {
                Rectangle()
                    .fill(YggTheme.Color.divider)
                    .frame(width: 3)
                Text(inlineStyled(text))
                    .font(YggTheme.Typography.body.italic())
                    .foregroundStyle(YggTheme.Color.textSecondary)
            }
        case .codeBlock(let text, _):
            Text(text)
                .font(YggTheme.Typography.monospaceBody)
                .padding(YggTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(YggTheme.Color.tertiaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
        case .horizontalRule:
            Divider()
        }
    }

    /// Wraps note text for `Text(LocalizedStringKey:)`'s inline markdown
    /// support, escaping literal `%` first — vault content is arbitrary
    /// human/agent-authored text, not a format string, but an unescaped `%d`
    /// or `%@` substring would otherwise be read as one.
    private func inlineStyled(_ text: String) -> LocalizedStringKey {
        LocalizedStringKey(text.replacingOccurrences(of: "%", with: "%%"))
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        default: return YggTheme.Typography.sectionHeader
        }
    }
}
