import SwiftUI

/// Sets up an export. Starting it closes the sheet; the toolbar shows the progress.
struct ExportSheet: View {
    @Bindable var model: ExportModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                Section("Destination") {
                    folderRows
                    photosRows
                }
                Section("Format") {
                    LabeledContent("Quality") {
                        HStack(spacing: 10) {
                            TrackSlider(
                                value: Binding(get: { model.quality }, set: { model.quality = ($0 * 100).rounded() / 100 }),
                                range: 0.5...1,
                                origin: 0.5
                            )
                            .frame(width: 160)
                            Text("\(model.qualityPercent)")
                                .monospacedDigit()
                                .frame(width: 26, alignment: .trailing)
                        }
                    }
                    Toggle(isOn: $model.includeMetadata) {
                        Text("Include Metadata")
                        Text("Camera, lens, capture date and location")
                    }
                    .accessibilityLabel("Include Metadata")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.outputFolder) { await model.refreshExistingNames() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ThumbnailStack(images: model.thumbnails)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.jobs.count == 1 ? "Export 1 Photo" : "Export \(model.jobs.count) Photos")
                    .font(.title3.weight(.semibold))
                Text(model.jobs.count == 1
                     ? "Full-size sRGB JPEG · \(model.jobs.first.map { Exporter.fileName(for: $0.source) } ?? "")"
                     : "Full-size sRGB JPEGs, named like the originals")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var folderRows: some View {
        Toggle(isOn: $model.exportsToFolder) {
            Text("Save to Folder")
            Text("JPEG files you can share or archive")
        }
        .accessibilityLabel("Save to Folder")
        if model.exportsToFolder {
            LabeledContent {
                Button(model.outputFolder == nil ? "Choose…" : "Change…") { model.chooseOutputFolder() }
            } label: {
                if let folder = model.outputFolder {
                    Label {
                        Text(folder.lastPathComponent)
                        Text(displayPath(of: folder.deletingLastPathComponent()))
                            .lineLimit(1)
                            .truncationMode(.head)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .help(displayPath(of: folder))
                } else {
                    Label("No folder chosen", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                }
            }
            let existing = model.existingCount(for: model.jobs.map(\.source))
            if existing > 0, let folder = model.outputFolder {
                Picker(selection: $model.existingFilePolicy) {
                    ForEach(ExistingFilePolicy.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("If a File Exists")
                    let place = "“\(folder.lastPathComponent)”"
                    Text(model.jobs.count == 1 ? "This photo is already in \(place)."
                         : existing == model.jobs.count ? "All of these photos are already in \(place)."
                         : "\(existing) of these photos \(existing == 1 ? "is" : "are") already in \(place).")
                }
            }
        }
    }

    @ViewBuilder
    private var photosRows: some View {
        Toggle(isOn: $model.addsToPhotos) {
            Text("Add to Photos")
            Text("Imported into your library, ready for iCloud")
        }
        .accessibilityLabel("Add to Photos")
        if model.addsToPhotos && model.isPhotosAccessDenied {
            LabeledContent {
                Button("Open Settings") { PhotosImporter.openPrivacySettings() }
            } label: {
                Label {
                    Text("Silver can’t add photos")
                    Text("Allow it in Privacy & Security, under Photos.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isRequestingAccess {
                ProgressView().controlSize(.small)
                Text("Waiting for access to Photos…")
            } else if model.isExporting {
                Text("Starts after the current export.")
            }
            Spacer()
            Button("Cancel") { model.isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Export") { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Up to three thumbnails, stacked: the first in front, the others smaller and darker behind it.
private struct ThumbnailStack: View {
    let images: [CGImage]

    var body: some View {
        ZStack {
            if images.isEmpty {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            // The first photo on top.
            ForEach(Array(images.enumerated()).reversed(), id: \.offset) { index, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 52, maxHeight: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    .brightness(-0.2 * Double(index))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .scaleEffect(1 - 0.12 * Double(index))
                    .offset(y: -7 * Double(index))
            }
        }
        .frame(width: 60, height: 60)
        .offset(y: images.count > 1 ? 5 : 0)
    }
}

/// A folder path with the home folder shown as “~”. The sandbox's home is the app container, so
/// the user's actual home folder is looked up.
func displayPath(of url: URL) -> String {
    let path = url.path(percentEncoded: false)
    guard let home = userHomePath, path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}

private let userHomePath: String? = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) }

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
