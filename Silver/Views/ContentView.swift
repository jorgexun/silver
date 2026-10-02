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
                .inspector(isPresented: $library.isInspectorPresented) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 290, max: 380)
                }
                .toolbar { toolbar }
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

    /// The photo count, or in the loupe the active photo's position.
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

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $library.showOriginal) {
                Label("Show Original", systemImage: "square.split.2x1")
            }
            .help("Show Original (\\): tap to switch, hold to peek")
            .disabled(library.activePhoto == nil || library.isCropping || library.viewMode != .loupe)

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
