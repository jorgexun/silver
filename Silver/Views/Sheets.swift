import SwiftUI

struct ExportSheet: View {
    @Bindable var model: ExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .configuring:
                configuration
            case .exporting(let completed, let total):
                progress(completed: completed, total: total)
            case .finished(let summary):
                finished(summary)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(model.isExporting)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.jobs.count == 1 ? "Export 1 Photo" : "Export \(model.jobs.count) Photos")
                .font(.headline)

            Form {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.outputFolder?.path(percentEncoded: false) ?? "None")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(model.outputFolder == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { model.chooseOutputFolder() }
                    }
                }
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $model.quality, in: 0.5...1, step: 0.01)
                        Text("\(Int((model.quality * 100).rounded()))")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                LabeledContent("Format", value: "JPEG, sRGB")
                LabeledContent("File Names", value: "Same as original")
                Picker("If File Exists", selection: $model.existingFilePolicy) {
                    ForEach(ExistingFilePolicy.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Include metadata (EXIF, GPS)", isOn: $model.includeMetadata)
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.outputFolder == nil)
            }
        }
    }

    private func progress(completed: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporting…").font(.headline)
            ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                Text("\(completed) of \(total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(_ summary: ExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(summary.wasCancelled ? "Export Stopped" : "Export Complete").font(.headline)
            } icon: {
                Image(systemName: summary.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.failures.isEmpty ? .green : .yellow)
            }
            Text("\(summary.exported.count) JPEG \(summary.exported.count == 1 ? "file" : "files") saved to \(summary.folder.lastPathComponent).")
                .foregroundStyle(.secondary)

            if !summary.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.failures) { failure in
                            Text("\(failure.fileName): \(failure.message)")
                                .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            HStack {
                Button("Show in Finder") { model.revealInFinder() }
                Spacer()
                Button("Done") { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct CopyOptionsSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var groups: AdjustmentGroups = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy Adjustments").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                toggle("Light", detail: "Exposure, Contrast, Highlights, Shadows", group: .light)
                toggle("White Balance", detail: "Temperature, Tint", group: .whiteBalance)
                toggle("Color", detail: "Vibrance, Saturation", group: .color)
                toggle("Crop & Straighten", detail: nil, group: .geometry)
            }
            HStack {
                Button("Select All") { groups = .all }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    library.copyAdjustments(groups: groups)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groups.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { groups = library.clipboardGroups }
    }

    private func toggle(_ title: String, detail: String?, group: AdjustmentGroups) -> some View {
        Toggle(isOn: Binding(
            get: { groups.contains(group) },
            set: { if $0 { groups.insert(group) } else { groups.remove(group) } }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
