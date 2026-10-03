import SwiftUI

/// The toolbar item for a background export: the system spinner while it runs, its spokes
/// lighting up as photos are done, then how it went.
/// Clicking it shows the details. `ExportModel` decides when the result goes away.
struct ExportActivityButton: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        @Bindable var export = library.export
        let help = export.progress?.label ?? export.result?.title ?? ""
        Button {
            export.isShowingActivity.toggle()
        } label: {
            // A label with a symbol, so the toolbar keeps it in the group with the buttons next
            // to it. A drawn shape got a group of its own.
            Label {
                Text(help)
            } icon: {
                icon
            }
        }
        .help(help)
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
                Image(systemName: "progress.indicator", variableValue: progress.fraction)
            }
        } else if export.result?.isClean == true {
            Image(systemName: "checkmark.circle")
        } else {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
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
