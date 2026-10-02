import SwiftUI

struct GridView: View {
    @Environment(LibraryModel.self) private var library
    @State private var viewport: CGSize = .zero
    /// Thumbnail size when a pinch began.
    @State private var pinchStartSize: Double?

    private static let spacing: CGFloat = 8
    private static let padding: CGFloat = 16

    var body: some View {
        let size = library.thumbnailSize

        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.6), spacing: Self.spacing)], spacing: Self.spacing) {
                    ForEach(library.photos) { photo in
                        let isSelected = library.selection.contains(photo.id)
                        ThumbnailCell(
                            photo: photo,
                            isSelected: isSelected,
                            // With nothing selected, the active photo isn't marked.
                            isActive: isSelected && library.activeID == photo.id
                        )
                        .frame(height: size)
                        .id(photo.id)
                        .onTapGesture(count: 2) { library.open(photo) }
                        .simultaneousGesture(TapGesture().onEnded {
                            library.click(photo, modifiers: NSEvent.modifierFlags)
                        })
                        .contextMenu { PhotoContextMenu(photo: photo) }
                    }
                }
                .padding(Self.padding)
                // Clicking between or below the photos deselects them, as in Finder and Photos.
                .frame(maxWidth: .infinity, minHeight: viewport.height, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) { library.deselectAll() }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
            .onChange(of: columns, initial: true) { library.gridColumns = columns }
            // Pinching resizes the thumbnails, as in Photos.
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStartSize ?? library.thumbnailSize
                        pinchStartSize = start
                        let sizes = LibraryModel.thumbnailSizes
                        library.thumbnailSize = min(max(start * value.magnification, sizes.lowerBound), sizes.upperBound)
                    }
                    .onEnded { _ in pinchStartSize = nil }
            )
            .onAppear {
                if let id = library.activeID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: library.activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .background(Color.canvas)
    }

    /// Columns the adaptive grid fits: as many of the minimum width as there's room for.
    private var columns: Int {
        let width = viewport.width - Self.padding * 2
        return max(Int((width + Self.spacing) / (library.thumbnailSize + Self.spacing)), 1)
    }
}

/// A photo in the grid. A tile appears behind it on hover and selection, with a ring when
/// selected that is strongest for the active photo. The name shows on hover.
struct ThumbnailCell: View {
    let photo: Photo
    let isSelected: Bool
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isActive ? 0.16 : isSelected ? 0.1 : isHovering ? 0.05 : 0))
            if let thumbnail = photo.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .overlay(alignment: .bottomTrailing) {
                        if photo.isEdited { EditedBadge().padding(5) }
                    }
                    .padding(10)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .selectionRing(isSelected, isActive: isActive, cornerRadius: 8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(photo.name)
    }
}

/// Commands for a right-clicked photo. Like Finder, they act on the whole selection when the
/// photo is part of it, and otherwise on just that photo, without changing the selection.
struct PhotoContextMenu: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo

    var body: some View {
        let targets = library.contextTargets(for: photo)
        let count = targets.count
        Button("Copy Adjustments") { library.copyAdjustments(from: photo) }
        Button(count > 1 ? "Paste Adjustments to \(count) Photos" : "Paste Adjustments") {
            library.pasteAdjustments(to: targets)
        }
        .disabled(library.clipboard == nil || library.isCropping)
        Button(count > 1 ? "Reset \(count) Photos" : "Reset Adjustments") {
            library.resetAdjustments(of: targets)
        }
        .disabled(targets.allSatisfy { !$0.isEdited } || library.isCropping)
        Divider()
        Button(count > 1 ? "Export \(count) Photos…" : "Export Photo…") { library.exportPhotos(targets) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
    }
}

struct FilmstripView: View {
    @Environment(LibraryModel.self) private var library

    /// Height of the strip, including its padding.
    static let height = FilmstripCell.imageHeight + FilmstripCell.inset * 2 + 18

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(library.photos) { photo in
                        FilmstripCell(
                            photo: photo,
                            isSelected: library.selection.contains(photo.id),
                            isActive: library.activeID == photo.id
                        )
                        .id(photo.id)
                        .onTapGesture {
                            library.click(photo, modifiers: NSEvent.modifierFlags)
                        }
                        .contextMenu { PhotoContextMenu(photo: photo) }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: Self.height)
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

/// A photo in the filmstrip, at its own aspect ratio so the strip wastes no space.
private struct FilmstripCell: View {
    let photo: Photo
    let isSelected: Bool
    let isActive: Bool

    static let imageHeight: CGFloat = 62
    /// Room for the selection ring around the image.
    static let inset: CGFloat = 3

    var body: some View {
        let aspect = photo.thumbnail.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
        let width = Self.imageHeight * min(max(aspect, 0.5), 2.5)
        Group {
            if let thumbnail = photo.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.05)
            }
        }
        .frame(width: width, height: Self.imageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(alignment: .bottomTrailing) {
            if photo.isEdited { EditedBadge(size: 13).padding(3) }
        }
        .padding(Self.inset)
        .selectionRing(isSelected, isActive: isActive, cornerRadius: 5)
        .contentShape(Rectangle())
        .help(photo.name)
    }
}
