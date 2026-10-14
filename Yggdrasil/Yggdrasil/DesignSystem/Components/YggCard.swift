import SwiftUI

// MARK: - Page surface

/// The backdrop behind every Yggdrasil page.
/// - Dark: `bg-base` with the faint 32 pt cyan grid.
/// - Shell: the night city (near-black base, neon sign glows, vertical glitch
///   streaks, scanlines). Static by design: the web's 600 s palette cycle is an
///   opt-in effect and is not ported.
struct YggBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .light {
            YggCityBackdrop()
        } else {
            YggTheme.Color.background
                .overlay(YggGrid(spacing: 32).stroke(YggTheme.Material.darkGrid, lineWidth: 1))
        }
    }
}

private struct YggGrid: Shape {
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var xPos: CGFloat = 0
        while xPos <= rect.maxX {
            path.move(to: CGPoint(x: xPos, y: 0))
            path.addLine(to: CGPoint(x: xPos, y: rect.maxY))
            xPos += spacing
        }
        var yPos: CGFloat = 0
        while yPos <= rect.maxY {
            path.move(to: CGPoint(x: 0, y: yPos))
            path.addLine(to: CGPoint(x: rect.maxX, y: yPos))
            yPos += spacing
        }
        return path
    }
}

private struct YggCityBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let signs = YggTheme.Material.citySigns
            ZStack {
                LinearGradient(colors: YggTheme.Material.cityBase, startPoint: .top, endPoint: .bottom)
                // Corner fields.
                RadialGradient(
                    colors: [signs[0].opacity(0.55), .clear], center: .topTrailing,
                    startRadius: 0, endRadius: max(size.width, size.height) * 0.7
                )
                RadialGradient(
                    colors: [signs[1].opacity(0.45), .clear], center: .bottomLeading,
                    startRadius: 0, endRadius: max(size.width, size.height) * 0.7
                )
                // Small neon "sign" glows.
                ForEach(Array(Self.signPositions.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(signs[index % signs.count])
                        .frame(width: 160, height: 160)
                        .blur(radius: 60)
                        .opacity(0.8)
                        .position(x: point.x * size.width, y: point.y * size.height)
                }
                // Vertical glitch streaks.
                ForEach(Array(Self.streaks.enumerated()), id: \.offset) { index, streak in
                    let tone: Color = index.isMultiple(of: 3)
                        ? Color.white.opacity(0.22)
                        : signs[index % signs.count].opacity(0.4)
                    Rectangle()
                        .fill(tone)
                        .frame(width: streak.width)
                        .position(x: streak.x * size.width, y: size.height / 2)
                }
                YggScanlines(spacing: 4).fill(.black.opacity(0.18))
            }
        }
        .accessibilityHidden(true)
    }

    private static let signPositions: [CGPoint] = [
        CGPoint(x: 0.12, y: 0.18), CGPoint(x: 0.84, y: 0.32), CGPoint(x: 0.28, y: 0.62),
        CGPoint(x: 0.72, y: 0.78), CGPoint(x: 0.5, y: 0.08), CGPoint(x: 0.92, y: 0.94)
    ]

    private static let streaks: [(x: CGFloat, width: CGFloat)] = [
        (0.07, 1), (0.19, 1), (0.33, 2), (0.47, 1), (0.61, 1), (0.78, 2), (0.9, 1)
    ]
}

private struct YggScanlines: Shape {
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var yPos: CGFloat = 0
        while yPos <= rect.maxY {
            path.addRect(CGRect(x: 0, y: yPos, width: rect.width, height: 1))
            yPos += spacing
        }
        return path
    }
}

/// The porcelain sheet: frosted glass over the city, with cyan/red rim light.
/// In Dark it is the plain `bg-surface`.
struct YggSheetBackground: View {
    var cornerRadius: CGFloat = YggTheme.Radius.card
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .light {
            let shape = RoundedRectangle(cornerRadius: YggTheme.Material.shellPanelRadius, style: .continuous)
            shape
                .fill(LinearGradient(
                    stops: YggTheme.Material.sheetStops,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(alignment: .topTrailing) { YggPanelSeam() }
                .shadow(color: YggTheme.Material.rimCyan.opacity(0.45), radius: 14, x: -6)
                .shadow(color: YggTheme.Material.rimRed.opacity(0.45), radius: 14, x: 6)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(YggTheme.Color.secondaryBackground)
        }
    }
}

extension View {
    /// Puts a page on the Yggdrasil backdrop. Scrollable containers (`List`,
    /// `Form`, `ScrollView`) drop their system background so the backdrop
    /// shows; in Shell a porcelain sheet sits inset on the city.
    func yggPage() -> some View {
        modifier(YggPageModifier())
    }
}

private struct YggPageModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isShell = colorScheme == .light
        content
            .scrollContentBackground(.hidden)
            // Shell: dark glass top bar on the city. The tab bar is left to the
            // system: on iPadOS it floats at the top and a forced background
            // there covers the page top.
            .toolbarBackground(YggTheme.Material.glass, for: .navigationBar)
            .toolbarBackground(isShell ? .visible : .automatic, for: .navigationBar)
            .toolbarColorScheme(isShell ? .dark : nil, for: .navigationBar)
            .background {
                ZStack {
                    YggBackdrop()
                    if colorScheme == .light {
                        YggSheetBackground()
                            .padding(YggTheme.Material.frameGap)
                    }
                }
                .ignoresSafeArea()
            }
    }
}

/// Faint suit panel-seam line drawn in one corner of a porcelain sheet.
private struct YggPanelSeam: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 28, y: 0))
            path.addLine(to: CGPoint(x: 40, y: 12))
            path.addLine(to: CGPoint(x: 40, y: 44))
        }
        .stroke(YggTheme.Color.textPrimary.opacity(0.18), lineWidth: 1)
        .frame(width: 40, height: 44)
        .padding(10)
        .accessibilityHidden(true)
    }
}

/// List/Form row surface. Dark: `bg-surface`. Shell: a lighter, more
/// translucent porcelain layer so the city still glows through the sheet.
struct YggRowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .light {
            Rectangle()
                .fill(Color.white.opacity(0.42))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(YggTheme.Color.textPrimary.opacity(0.08)).frame(height: 1)
                }
        } else {
            YggTheme.Color.secondaryBackground
        }
    }
}

extension View {
    /// Applies the Yggdrasil row surface to every row inside a `List`/`Form`.
    func yggRows() -> some View {
        listRowBackground(YggRowBackground())
    }
}

// MARK: - Components

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
        .background(YggSheetBackground())
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

/// Primary action. Dark: Norse-gold fill. Shell: solid graphite with a
/// cyan/red chromatic split on its edges.
struct YggPrimaryButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(YggTheme.Typography.body.weight(.semibold))
                .foregroundStyle(YggTheme.Color.onPrimaryFill)
                .frame(maxWidth: .infinity)
                .padding(.vertical, YggTheme.Spacing.sm + YggTheme.Spacing.xs)
                .background(buttonShape.fill(YggTheme.Color.primaryFill))
                .shadow(color: colorScheme == .light ? YggTheme.Material.splitCyan : .clear, radius: 0, x: -1.5)
                .shadow(color: colorScheme == .light ? YggTheme.Material.splitRed : .clear, radius: 0, x: 1.5)
        }
        .buttonStyle(.plain)
        .contentShape(buttonShape)
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: colorScheme == .light ? YggTheme.Material.shellPanelRadius : YggTheme.Radius.control,
            style: .continuous
        )
    }
}

/// Status marker: a small square in the mark tone with an ink-tone label
/// (Shell grammar — no pills). Works in both themes.
struct YggStatusMarker: View {
    let label: String
    let ink: Color
    let mark: Color

    var body: some View {
        HStack(spacing: YggTheme.Spacing.xs + 2) {
            Rectangle().fill(mark).frame(width: 7, height: 7)
            Text(label.uppercased())
                .font(YggTheme.Typography.statusLabel)
                .tracking(1.2)
                .foregroundStyle(ink)
        }
        .accessibilityElement(children: .combine)
    }
}
