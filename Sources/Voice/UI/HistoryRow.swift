import SwiftUI
import VoiceCore

struct HistoryRow: View {
    let item: HistoryItem
    let isSelected: Bool
    let isCursor: Bool
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KindBadge(item: item)
            VStack(alignment: .leading, spacing: 7) {
                let images = item.displayImages
                if !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(images.prefix(4).enumerated()), id: \.offset) { index, path in
                            ThumbnailView(path: path, height: 64, badge: item.kind == .session ? index + 1 : nil)
                        }
                        if images.count > 4 {
                            Text("+\(images.count - 4)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let primary = item.primaryText
                if !primary.isEmpty {
                    Text(primary)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .lineSpacing(2)
                        .foregroundStyle(item.isLink ? Color.accentColor : .primary)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(item.metaParts(now: context.date).joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(isCursor ? 0.24 : 0.14) }
        if isCursor { return Color.primary.opacity(0.08) }
        return .clear
    }
}

/// One tinted symbol per row saying what the item is, instead of a grid of mostly-disabled icons.
struct KindBadge: View {
    let item: HistoryItem
    var size: CGFloat = 28

    var body: some View {
        let style = item.kindStyle
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(style.tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(style.tint.opacity(0.16))
            )
            .help(style.name)
    }
}
