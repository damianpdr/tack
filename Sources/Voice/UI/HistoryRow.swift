import SwiftUI
import VoiceCore

struct HistoryRow: View {
    let item: HistoryItem
    let isSelected: Bool
    let isCursor: Bool
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ContentIcons(item: item)
            VStack(alignment: .leading, spacing: 6) {
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
                        .foregroundStyle(.primary)
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
        .padding(.vertical, 8)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .background(background)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color.purple)
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
    }

    private var background: Color {
        if isSelected { return Color.purple.opacity(isCursor ? 0.2 : 0.13) }
        if isCursor { return Color.primary.opacity(0.07) }
        return .clear
    }
}

private struct ContentIcons: View {
    let item: HistoryItem

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                icon("mic.fill", active: item.hasAudio, tint: .red)
                icon("photo", active: !item.imagePaths.isEmpty, tint: .blue)
            }
            GridRow {
                icon("folder.fill", active: !item.filePaths.isEmpty, tint: .orange)
                Text("T")
                    .font(.system(size: 11, weight: .bold, design: .serif))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(item.hasTextContent ? Color.green : Color.secondary.opacity(0.35))
            }
        }
        .padding(.top, 2)
    }

    private func icon(_ name: String, active: Bool, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 16, height: 16)
            .foregroundStyle(active ? tint : Color.secondary.opacity(0.35))
    }
}
