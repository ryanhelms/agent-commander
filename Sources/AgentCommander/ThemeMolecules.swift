import SwiftUI

// ATOMIC LEVEL: Molecules (theme layer).
//
//   ThemeThumbnail   a small window drawn in one theme's own tokens
//   ThemeChoiceCard  ThemeThumbnail + name + what the theme looks like, as one selectable card
//
// The thumbnail draws the theme it is given. The card around it uses the current theme.

/// A small window in the given theme: its rail, two panels with a state mark, and a primary action.
struct ThemeThumbnail: View {
    let theme: Theme

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: min(6, theme.radius.tile * 2), style: .continuous)
        HStack(spacing: 0) {
            rail
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(theme.color.foreground.color).frame(width: 34, height: 3)
                HStack(spacing: 4) {
                    panel(mark: theme.color.working)
                    panel(mark: theme.color.attention)
                }
                HStack(spacing: 0) {
                    Capsule().fill(theme.color.secondary.color).frame(width: 22, height: 2)
                    Spacer(minLength: 0)
                    theme.controlShape.fill(theme.surface.primaryFill.style).frame(width: 24, height: 8)
                }
            }
            .padding(6)
        }
        .frame(width: 150, height: 90)
        .background(theme.color.window.color)
        .clipShape(frame)
        .overlay { frame.strokeBorder(theme.color.border.color) }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var rail: some View {
        let rows = VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<4, id: \.self) { index in
                Capsule().fill(theme.color.secondary.color.opacity(index == 1 ? 1 : 0.5)).frame(width: index == 1 ? 16 : 12, height: 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 9)
        .frame(width: 30, alignment: .leading)
        switch theme.material.window {
        case .glass:
            rows.background(LinearGradient(colors: [theme.color.foreground.color.opacity(0.20), theme.color.foreground.color.opacity(0.07)],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(3)
        case .opaque:
            rows.background(theme.color.well.color)
                .overlay(alignment: .trailing) { Rectangle().fill(theme.color.hair.color).frame(width: 1) }
        }
    }

    private func panel(mark: ThemeColor) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.tile / 3, style: .continuous)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Group {
                    switch theme.style.statusMark {
                    case .dot: Circle().fill(mark.color)
                    case .lamp: Rectangle().fill(mark.color)
                    }
                }
                .frame(width: 4, height: 4)
                Capsule().fill(theme.color.foreground.color).frame(width: 16, height: 2)
            }
            Capsule().fill(theme.color.secondary.color.opacity(0.6)).frame(height: 2)
            Capsule().fill(theme.color.secondary.color.opacity(0.6)).frame(width: 20, height: 2)
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.panelFill.style, in: shape)
        .overlay { shape.strokeBorder(theme.surface.panelEdge.color) }
    }
}

extension ThemeID {
    /// What the theme looks like, for the person choosing it.
    var detail: String {
        switch self {
        case .blackGlass: "Glass navigation, rounded cards and soft depth."
        case .console: "Hairline grids, square corners and monospaced data."
        }
    }
}

/// One theme as a selectable card.
struct ThemeChoiceCard: View {
    @Environment(\.theme) private var theme
    let option: Theme
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .center, spacing: Space.l) {
                ThemeThumbnail(theme: option)
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: 9) {
                        ChoiceMark(isSelected: isSelected)
                        Text(option.name).themeType(theme.type.name).foregroundStyle(.theme(\.color.foreground)).lineLimit(1)
                        Spacer(minLength: Space.xs)
                        if isSelected {
                            Text("Selected").themeType(theme.type.state).foregroundStyle(.theme(\.color.working))
                        }
                    }
                    Text(option.id.detail).themeType(theme.type.sub).foregroundStyle(.theme(\.color.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionCard(isSelected, radius: 11)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.name) theme. \(option.id.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("theme-choice-\(option.id.rawValue)")
    }
}

/// The mark of one option in an exclusive choice.
struct ChoiceMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Circle().strokeBorder(.theme(\.color.focus), lineWidth: 1)
                Circle().fill(.theme(\.color.focus)).padding(3)
            } else {
                Circle().strokeBorder(.theme(\.color.secondary), lineWidth: 1)
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}
