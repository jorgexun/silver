import SwiftUI

struct GridView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        @Bindable var library = library
        let size = library.thumbnailSize

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.6), spacing: 10)], spacing: 10) {
                        ForEach(library.photos) { photo in
                            ThumbnailCell(
                                photo: photo,
                                isSelected: library.selection.contains(photo.id),
                                isActive: library.activeID == photo.id
                            )
                            .frame(height: size + 20)
                            .id(photo.id)
                            .onTapGesture(count: 2) { library.open(photo) }
                            .simultaneousGesture(TapGesture().onEnded {
                                library.click(photo, modifiers: NSEvent.modifierFlags)
                            })
                            .contextMenu { PhotoContextMenu(photo: photo) }
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    if let id = library.activeID { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: library.activeID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "square.grid.3x3")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Slider(value: $library.thumbnailSize, in: 110...380)
                    .controlSize(.small)
                    .frame(width: 140)
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .background(Color.canvas)
    }

    private var statusText: String {
        let edited = library.photos.filter(\.isEdited).count
        var parts = ["\(library.photos.count) photos"]
        if library.selection.count > 1 { parts.append("\(library.selection.count) selected") }
        if edited > 0 { parts.append("\(edited) edited") }
        return parts.joined(separator: " · ")
    }
}

struct ThumbnailCell: View {
    let photo: Photo
    let isSelected: Bool
    let isActive: Bool
    var showsCaption = true

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isActive ? 0.16 : isSelected ? 0.09 : 0.03))
                if let thumbnail = photo.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .padding(showsCaption ? 10 : 5)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: isActive ? 2.5 : 1.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.isEdited {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(showsCaption ? 6 : 3)
                }
            }

            if showsCaption {
                Text(photo.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .contentShape(Rectangle())
        .help(photo.name)
    }
}

struct PhotoContextMenu: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo

    var body: some View {
        Button("Copy Adjustments") {
            library.select(photo)
            library.copyAdjustments()
        }
        Button("Paste Adjustments") {
            if !library.selection.contains(photo.id) { library.select(photo) }
            library.pasteAdjustments(toSelected: true)
        }
        .disabled(library.clipboard == nil)
        Button("Reset Adjustments") {
            if !library.selection.contains(photo.id) { library.select(photo) }
            library.resetAdjustments()
        }
        Divider()
        Button("Export JPEG…") {
            if !library.selection.contains(photo.id) { library.select(photo) }
            library.exportTargets()
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([photo.url])
        }
    }
}

struct FilmstripView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(library.photos) { photo in
                        ThumbnailCell(
                            photo: photo,
                            isSelected: library.selection.contains(photo.id),
                            isActive: library.activeID == photo.id,
                            showsCaption: false
                        )
                        .frame(width: 92)
                        .id(photo.id)
                        .onTapGesture {
                            library.click(photo, modifiers: NSEvent.modifierFlags)
                        }
                        .contextMenu { PhotoContextMenu(photo: photo) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .onAppear {
                if let id = library.activeID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: library.activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(white: 0.08))
    }
}
