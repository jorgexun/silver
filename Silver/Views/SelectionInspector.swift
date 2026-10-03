import SwiftUI

/// The inspector while several photos are selected in the grid: what the export will contain,
/// before opening the export window.
struct SelectionInspector: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        let photos = library.selectedPhotos

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SelectionHeader(photos: photos)
                ExportPlan(photos: photos)
                InspectorSection("Photos") {
                    LazyVStack(spacing: 2) {
                        ForEach(photos) { photo in
                            SelectedPhotoRow(photo: photo)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

/// A warning when names are taken in the export folder, and the button that opens the export
/// window. The only part that reads the export settings, so changing them in the export window
/// doesn't update the rest.
private struct ExportPlan: View {
    @Environment(LibraryModel.self) private var library
    let photos: [Photo]

    var body: some View {
        let export = library.export
        VStack(alignment: .leading, spacing: 10) {
            existingNote
            Button {
                library.exportPhotos()
            } label: {
                Text("Export \(photos.count) Photos…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Choose where to export and the quality, then export (⇧⌘E)")
        }
        // The model lists the folder again after an export.
        .task(id: export.outputFolder) { await export.refreshExistingNames() }
    }

    @ViewBuilder
    private var existingNote: some View {
        let export = library.export
        let existing = export.existingCount(for: photos.map(\.url))
        if existing > 0, export.exportsToFolder, let folder = export.outputFolder {
            let found = existing == 1 ? "1 photo already has a JPEG" : "\(existing) photos already have JPEGs"
            Text("\(found) in “\(folder.lastPathComponent)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How many photos are selected, how many are edited, and when they were taken.
private struct SelectionHeader: View {
    let photos: [Photo]

    var body: some View {
        let edited = photos.filter(\.isEdited).count
        VStack(alignment: .leading, spacing: 3) {
            Text("\(photos.count) Photos Selected")
                .font(.headline)
            Group {
                Text(edited == 0 ? "None edited" : edited == photos.count ? "All edited" : "\(edited) edited · \(photos.count - edited) not edited")
                if let dates = dateRange { Text(dates) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var dateRange: String? {
        let dates = photos.compactMap { $0.metadata?.captureDate }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return first.formatted(date: .abbreviated, time: .omitted)
        }
        return (first..<last).formatted(.interval.day().month(.abbreviated).year())
    }
}

/// A photo in the selection, with its output size. Hovering shows a button that takes it out
/// of the selection, and so out of the export.
private struct SelectedPhotoRow: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo
    @State private var isHovering = false

    private static let thumbnailSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = photo.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.white.opacity(0.05)
                }
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .overlay(alignment: .bottomTrailing) {
                if photo.isEdited { EditedBadge(size: 12).offset(x: 3, y: 3) }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(photo.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = photo.exportSize {
                    Text("\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button("Remove from Selection", systemImage: "minus.circle.fill") { library.deselect(photo) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from Selection")
                .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.white.opacity(isHovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
