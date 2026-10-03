import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        @Bindable var library = library
        @Bindable var export = library.export

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
        } detail: {
            content
                .toolbar { toolbar }
        }
        // On the split view, not the detail, so the inspector is a column with its own part of
        // the toolbar: the zoom slider then ends where the canvas does, and the photo actions sit
        // over the inspector. When it's hidden, they move next to the slider.
        .inspector(isPresented: $library.isInspectorPresented) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 290, max: 380)
                .toolbar { inspectorToolbar }
        }
        .onAppear { library.isWindowOpen = true }
        // Closing the window keeps the app running, so write pending edits now.
        .onDisappear {
            library.isWindowOpen = false
            library.flushSaves()
        }
        .navigationTitle(library.folderURL?.lastPathComponent ?? "Silver")
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $export.isPresented) {
            ExportSheet(model: library.export)
        }
        .sheet(isPresented: $library.isShowingCopyOptions) {
            CopyOptionsSheet()
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { library.alertMessage != nil }, set: { if !$0 { library.alertMessage = nil } }),
            presenting: library.alertMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath)
            guard !folders.isEmpty else { return false }
            library.addFolders(folders)
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.folders.roots.isEmpty {
            ContentUnavailableView {
                Label("No Folders", systemImage: "folder")
            } description: {
                Text("Add a folder of DNG or JPEG photos, or drop one here.")
            } actions: {
                Button("Add Folder…") { library.presentAddFolderPanel() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
        } else if library.folderURL == nil {
            ContentUnavailableView("Select a Folder", systemImage: "sidebar.leading", description: Text("Choose a folder in the sidebar."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
        } else if library.isScanning {
            ProgressView("Loading Photos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
        } else if library.photos.isEmpty {
            ContentUnavailableView {
                Label("No Photos", systemImage: "photo.on.rectangle")
            } description: {
                Text("This folder doesn’t contain any DNG or JPEG files. Photos in subfolders are shown when you select the subfolder.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
        } else {
            switch library.viewMode {
            case .grid: GridView()
            case .loupe: LoupeView()
            }
        }
    }

    /// The photo count and how many are edited, or in the loupe the active photo's position.
    private var subtitle: String {
        guard library.folderURL != nil, !library.isScanning, !library.photos.isEmpty else { return "" }
        let count = library.photos.count
        var parts: [String]
        if library.viewMode == .loupe, let index = library.activeIndex {
            parts = ["\(index + 1) of \(count)"]
        } else {
            parts = [count == 1 ? "1 photo" : "\(count) photos"]
        }
        if library.selection.count > 1 { parts.append("\(library.selection.count) selected") }
        if library.viewMode == .grid {
            let edited = library.photos.filter(\.isEdited).count
            if edited > 0 { parts.append("\(edited) edited") }
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var library = library

        ToolbarItem(placement: .principal) {
            Picker("View", selection: $library.viewMode) {
                Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                Label("Loupe", systemImage: "photo").tag(ViewMode.loupe)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Grid (G) / Loupe (E)")
            .disabled(library.photos.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) { ZoomSlider() }
    }

    @ToolbarContentBuilder
    private var inspectorToolbar: some ToolbarContent {
        @Bindable var library = library

        // Items in the inspector's part of the toolbar otherwise start at its leading edge.
        ToolbarSpacer(.flexible, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $library.showOriginal) {
                Label("Show Original", systemImage: "square.split.2x1")
            }
            .help("Show Original (\\): tap to switch, hold to peek")
            .disabled(library.activePhoto == nil || library.isCropping || library.viewMode != .loupe)

            if library.export.isExporting || library.export.result != nil {
                ExportActivityButton()
            }

            Button("Export", systemImage: "square.and.arrow.up") { library.exportPhotos() }
                .help(library.targetPhotos.count > 1 ? "Export \(library.targetPhotos.count) Photos (⇧⌘E)" : "Export Photo (⇧⌘E)")
                .disabled(library.targetPhotos.isEmpty)
        }

        // The inspector toggle gets its own group, apart from the photo actions.
        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button("Adjustments", systemImage: "sidebar.trailing") {
                library.isInspectorPresented.toggle()
            }
            .help("Show or Hide Adjustments (⌥⌘I)")
        }
    }
}

/// Thumbnail size in the grid; in the loupe, the zoom of the photo, from fit to 400%.
private struct ZoomSlider: View {
    @Environment(LibraryModel.self) private var library
    @State private var isSliding = false

    var body: some View {
        @Bindable var library = library
        let isGrid = library.viewMode == .grid

        HStack(spacing: 6) {
            Image(systemName: isGrid ? "square.grid.3x3" : "minus.magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Group {
                if isGrid {
                    TrackSlider(
                        value: $library.thumbnailSize,
                        range: LibraryModel.thumbnailSizes,
                        origin: LibraryModel.thumbnailSizes.lowerBound
                    )
                } else {
                    // Dragging zooms live; letting go settles on the zoom.
                    TrackSlider(
                        value: Binding(
                            get: { library.zoomSliderPosition },
                            set: { library.setZoomSliderPosition($0, live: isSliding) }
                        ),
                        range: 0...1,
                        origin: 0,
                        onEditingChanged: { editing in
                            isSliding = editing
                            if !editing { library.endLiveZoom() }
                        },
                        onReset: { library.exitZoom() }
                    )
                    .disabled(!library.canUseZoomSlider)
                }
            }
            .frame(width: 110)
            Image(systemName: isGrid ? "square.grid.2x2" : "plus.magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
        .help(isGrid ? "Thumbnail Size (⌘+ / ⌘−)" : "Zoom (⌘+ / ⌘−, Z for 100%)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isGrid ? "Thumbnail Size" : "Zoom")
        .disabled(library.photos.isEmpty)
    }
}
