import SwiftUI
import TackCore

/// The pill style as two cards with a still of each, like the appearance picker in System Settings.
struct PillStylePicker: View {
    @Binding var style: PillStyle
    /// Called when the user picks a different style.
    var onPick: (PillStyle) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(PillStyle.allCases, id: \.self) { option in
                Button {
                    guard option != style else { return }
                    style = option
                    onPick(option)
                } label: {
                    card(option)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.title): \(option.subtitle)")
                .accessibilityAddTraits(option == style ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func card(_ option: PillStyle) -> some View {
        let selected = option == style
        return VStack(spacing: 3) {
            PillStill(style: option)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.36, green: 0.42, blue: 0.55), Color(red: 0.15, green: 0.18, blue: 0.26)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1)
                )
                .padding(.bottom, 3)
            Text(option.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
            Text(option.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// A still of the pill mid-recording in either style: bars and a "figure 1" marker, with the glow when expressive.
private struct PillStill: View {
    let style: PillStyle
    private static let bars: [CGFloat] = [0.45, 0.8, 1.0, 0.65, 0.9, 0.5]

    var body: some View {
        let minimal = style == .minimal
        let accent = AnyShapeStyle(LinearGradient(colors: Brand.gradient, startPoint: .top, endPoint: .bottom))
        HStack(spacing: 6) {
            HStack(spacing: 1.5) {
                ForEach(Self.bars.indices, id: \.self) { index in
                    Capsule()
                        .fill(minimal ? AnyShapeStyle(Color.white.opacity(0.85)) : accent)
                        .frame(width: 2.5, height: 13 * Self.bars[index])
                }
            }
            Text("figure 1")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(minimal ? .white.opacity(0.9) : .black.opacity(0.85))
                .padding(.horizontal, 5)
                .frame(height: 13)
                .background(Capsule().fill(minimal ? AnyShapeStyle(Color.white.opacity(0.22)) : accent))
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Capsule().fill(.black).overlay(Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 0.5)))
        .background {
            if !minimal {
                Capsule()
                    .fill(LinearGradient(colors: Brand.gradient, startPoint: .leading, endPoint: .trailing))
                    .padding(.horizontal, -3)
                    .padding(.vertical, -1)
                    .blur(radius: 10)
                    .opacity(0.85)
            }
        }
    }
}

private extension PillStyle {
    var title: String {
        switch self {
        case .expressive: "Expressive"
        case .minimal: "Minimal"
        }
    }

    var subtitle: String {
        switch self {
        case .expressive: "Motion and sounds"
        case .minimal: "Quiet and still"
        }
    }
}
