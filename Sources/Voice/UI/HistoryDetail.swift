import AppKit
import SwiftUI
import VoiceCore

struct HistoryDetail: View {
    let model: AppModel
    let item: HistoryItem
    let onDelete: () -> Void

    var body: some View {
        let prompt = item.composed
        let isBusy = model.busyItemIDs.contains(item.id)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(isBusy: isBusy)
                    bodyText(prompt: prompt)
                    images
                    clips(prompt: prompt)
                    files
                    metadata
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actions(isBusy: isBusy)
                .padding(12)
        }
    }

    private func header(isBusy: Bool) -> some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(item.metaParts(now: context.date).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func bodyText(prompt: ComposedPrompt) -> some View {
        let text: String = switch item.kind {
        case .session: prompt.body
        case .text: item.text
        case .image: ""
        case .file: item.filePaths.joined(separator: "\n")
        }
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var images: some View {
        let paths = item.displayImages
        if item.kind == .image, let path = paths.first {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                ImagePreview(path: path)
            }
            .buttonStyle(.plain)
            .help(path)
        } else if !paths.isEmpty {
            section(HistoryFormat.count(paths.count, "image")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        } label: {
                            ThumbnailView(
                                path: path,
                                height: 90,
                                maxWidth: 140,
                                badge: item.kind == .session ? index + 1 : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .help(path)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func clips(prompt: ComposedPrompt) -> some View {
        if item.kind == .session, !prompt.clips.isEmpty {
            section(HistoryFormat.count(prompt.clips.count, "clip")) {
                ForEach(Array(prompt.clips.enumerated()), id: \.offset) { index, clip in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("clip \(index + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(clip)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        let paths = item.filePaths
        if !paths.isEmpty {
            section(HistoryFormat.count(paths.count, "file")) {
                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Label((path as NSString).lastPathComponent, systemImage: "doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.link)
                    .help(path)
                }
            }
        }
    }

    private var metadata: some View {
        section("Details") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("Created", HistoryFormat.absolute(item.createdAt))
                if let sourceApp = item.sourceApp {
                    row("Source", sourceApp)
                }
                if let duration = item.audioDuration {
                    row("Audio", HistoryFormat.duration(duration))
                }
                if let sessionDir = item.sessionDir {
                    row("Folder", sessionDir)
                }
            }
        }
    }

    private func actions(isBusy: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            actionButtons(isBusy: isBusy, compact: false)
            actionButtons(isBusy: isBusy, compact: true)
        }
    }

    private func actionButtons(isBusy: Bool, compact: Bool) -> some View {
        HStack(spacing: 8) {
            actionButton("Paste", icon: "arrow.turn.down.left", compact: compact) { model.paste([item]) }
                .buttonStyle(.borderedProminent)
            actionButton("Copy", icon: "doc.on.doc", compact: compact) { model.copy([item]) }
            if item.kind == .session, item.hasAudio, item.sessionDir != nil {
                actionButton("Re-transcribe", icon: "arrow.clockwise", compact: compact) {
                    Task { await model.retranscribe(item) }
                }
                .disabled(isBusy)
            }
            Spacer(minLength: 0)
            actionButton("Reveal in Finder", icon: "folder", compact: true) { model.revealInFinder(item) }
            actionButton("Delete", icon: "trash", compact: true, action: onDelete)
        }
    }

    private func actionButton(_ title: String, icon: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if compact {
                Image(systemName: icon)
            } else {
                Text(title)
            }
        }
        .help(title)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
    }
}
