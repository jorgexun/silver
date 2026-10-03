import SwiftUI

/// The toolbar's Export button. While an export runs it shows the progress instead: the system
/// spinner until the first photo is done, then a ring that closes as photos are done, then how
/// it went, until `ExportModel` dismisses the result. Clicking it meanwhile shows the details;
/// more photos can still be exported from the menus.
struct ExportButton: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        @Bindable var export = library.export
        // What the export is doing, while it shows in place of the button's icon.
        let activity = export.progress?.label ?? export.result?.title
        // Counted only when idle: the body runs for each photo exported.
        let count = activity == nil ? library.targetPhotos.count : 0
        Button {
            if activity != nil {
                export.isShowingActivity.toggle()
            } else {
                library.exportPhotos()
            }
        } label: {
            // A label with a symbol, so the toolbar keeps it in the group with the buttons next
            // to it. A drawn shape got a group of its own.
            Label {
                Text(activity ?? "Export")
            } icon: {
                // Every state at the ring's width: the spinner and the warning are wider (19 pt
                // to the ring's 18 at 15 pt) and widened the toolbar's glass group.
                Image(systemName: "circle")
                    .hidden()
                    .overlay { icon }
            }
        }
        .help(activity ?? (count > 1 ? "Export \(count) Photos (⇧⌘E)" : "Export Photo (⇧⌘E)"))
        .disabled(activity == nil && count == 0)
        .popover(isPresented: $export.isShowingActivity, arrowEdge: .bottom) {
            ExportActivityView(model: export)
        }
    }

    @ViewBuilder
    private var icon: some View {
        let export = library.export
        if let progress = export.progress {
            if progress.completed == 0 {
                // Nothing to show yet: a single photo takes a few seconds.
                Image(systemName: "progress.indicator")
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing)
            } else {
                // Variable Draw draws the circle's stroke clockwise from the top, over a dimmed
                // track.
                Image(systemName: "circle", variableValue: progress.fraction)
                    .symbolVariableValueMode(.draw)
                    .animation(.easeOut(duration: 0.3), value: progress.fraction)
            }
        } else if let result = export.result {
            if result.isClean {
                Image(systemName: "checkmark.circle")
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }
        } else {
            Image(systemName: "square.and.arrow.up")
        }
    }
}

/// The export's progress with a Stop button, or what the last export did.
struct ExportActivityView: View {
    let model: ExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = model.progress {
                running(progress)
            } else if let result = model.result {
                finished(result)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func running(_ progress: ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.label)
                .font(.headline)
                .monospacedDigit()
            ProgressView(value: progress.fraction)
            HStack {
                Text(progress.current ?? " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Stop") { model.cancel() }
            }
        }
    }

    private func finished(_ result: ExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(result.title).font(.headline)
            } icon: {
                Image(systemName: result.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.isClean ? .green : .yellow)
            }
            Text(result.outcome)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !result.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.failures) { failure in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(failure.fileName)
                                Text(failure.message).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
            }

            let showsFinder = !result.exported.isEmpty
            let showsPhotos = (result.addedToPhotos ?? 0) > 0
            if showsFinder || showsPhotos {
                HStack {
                    if showsFinder {
                        Button("Show in Finder") { model.revealInFinder() }
                    }
                    if showsPhotos {
                        Button("Open Photos") { PhotosImporter.openPhotos() }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
