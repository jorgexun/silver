import AppKit
import Observation

enum ViewMode: Hashable {
    case grid
    case loupe
}

/// 100% view of the active photo.
struct ZoomState: Equatable {
    let photoID: Photo.ID
    /// Clicked point, normalized to the displayed image (top-left origin).
    let focus: CGPoint
    /// Where that point was in the canvas, normalized to the canvas size; it stays under the cursor.
    let anchor: CGPoint
}

/// Full-resolution pixels for part of the active photo, shown at 100%.
struct DetailImage {
    let photoID: Photo.ID
    let image: CGImage
    /// Area covered, in full-resolution output pixels (top-left origin).
    let rect: CGRect
}

struct PreviewImage {
    let photoID: Photo.ID
    let image: CGImage
    /// Whether crop and straighten were applied.
    let hasGeometry: Bool
}

/// App state: sidebar folders, the open folder, selection, editing, undo and background work.
@Observable
final class LibraryModel {
    // MARK: Folder

    private(set) var folderURL: URL?
    private(set) var photos: [Photo] = []
    private(set) var isScanning = false
    private var photosByID: [Photo.ID: Photo] = [:]

    // MARK: Selection

    private(set) var selection: Set<Photo.ID> = []
    private(set) var activeID: Photo.ID?
    private var anchorID: Photo.ID?

    // MARK: View state

    var viewMode: ViewMode = .grid {
        didSet {
            guard viewMode != oldValue else { return }
            if viewMode == .loupe {
                requestPreview()
            } else {
                endCrop()
                exitZoom()
            }
        }
    }
    private(set) var isCropping = false
    var showOriginal = false {
        didSet { if showOriginal != oldValue { requestPreview() } }
    }
    var thumbnailSize: Double = 180
    var isInspectorPresented = true
    var alertMessage: String?

    // MARK: Preview

    private(set) var preview: PreviewImage?

    // MARK: Zoom

    private(set) var zoom: ZoomState?
    /// Full-resolution output size of the zoomed photo, once known.
    private(set) var zoomFullSize: CGSize?
    private(set) var detail: DetailImage?
    /// Visible area plus a margin, in full-resolution output pixels.
    private var detailViewport: CGRect?
    /// Center of the visible area, normalized to the image; carried over to the next photo.
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    private var detailTask: Task<Void, Never>?
    private var detailPending = false
    /// Edits made while zoomed only re-render the visible detail; the fit preview catches up on exit.
    private var previewStaleWhileZoomed = false
    private let renderer = PreviewRenderer()
    private var renderTask: Task<Void, Never>?
    private var renderPending = false
    private var renderForThumbnail = false

    // MARK: Clipboard

    private(set) var clipboard: EditSettings?
    private(set) var clipboardGroups: AdjustmentGroups = .default
    var isShowingCopyOptions = false

    // MARK: Editing

    private struct Change {
        let id: Photo.ID
        let before: EditSettings
        let after: EditSettings
    }

    private struct EditRecord {
        let name: String
        let changes: [Change]
    }

    private var undoStack: [EditRecord] = []
    private var redoStack: [EditRecord] = []
    /// Photo and settings when the current slider drag began.
    private var interactiveStart: (id: Photo.ID, settings: EditSettings)?
    private var cropSessionStart: EditSettings?
    private var straightenBase: CropRect?

    // MARK: Background work

    private var thumbnailQueue: [Photo.ID] = []
    private var thumbnailTask: Task<Void, Never>?
    private var dirtyIDs: Set<Photo.ID> = []
    private var saveTask: Task<Void, Never>?
    private var didReportSaveError = false

    let export = ExportModel()
    let folders = SourceFolders()

    // MARK: - Derived state

    var activePhoto: Photo? { activeID.flatMap { photosByID[$0] } }

    var selectedPhotos: [Photo] { photos.filter { selection.contains($0.id) } }

    /// Selected photos, or the active photo when nothing is selected.
    var targetPhotos: [Photo] {
        let selected = selectedPhotos
        if !selected.isEmpty { return selected }
        return activePhoto.map { [$0] } ?? []
    }

    var canUndo: Bool { !undoStack.isEmpty && !isCropping }
    var canRedo: Bool { !redoStack.isEmpty && !isCropping }
    var undoActionName: String? { undoStack.last?.name }
    var redoActionName: String? { redoStack.last?.name }

    var activeIndex: Int? { activeID.flatMap { id in photos.firstIndex { $0.id == id } } }

    // MARK: - Opening folders

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to add to the sidebar."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addFolders(panel.urls)
    }

    /// Adds folders to the sidebar and shows the first one.
    func addFolders(_ urls: [URL]) {
        let added = folders.add(urls)
        if let first = added.first { openFolder(first) }
    }

    func removeFolder(_ root: FolderNode) {
        if let folderURL, SourceFolders.url(folderURL, isInside: root.url) {
            closeFolder(forget: true)
        }
        folders.remove(root)
    }

    /// Restores sidebar folders and the last selected folder.
    func restoreSession() {
        folders.restore()
        openSavedFolder()
        observeVolumes()
    }

    private func openSavedFolder() {
        if let path = UserDefaults.standard.string(forKey: Self.selectedFolderKey) {
            let url = SourceFolders.normalized(URL(fileURLWithPath: path))
            if folders.root(containing: url)?.isAvailable == true, FileManager.default.fileExists(atPath: url.path) {
                openFolder(url)
                folders.reveal(url)
                return
            }
        }
        if let first = folders.roots.first(where: \.isAvailable) { openFolder(first.url) }
    }

    private var volumeObservers: [NSObjectProtocol] = []

    /// Folders on external drives come and go; re-check them when volumes change or the app
    /// becomes active.
    private func observeVolumes() {
        let workspace = NSWorkspace.shared.notificationCenter
        // Delivered on the main queue; the model lives for the whole app session.
        let handler: @Sendable (Notification) -> Void = { [self] _ in
            MainActor.assumeIsolated { volumesChanged() }
        }
        volumeObservers = [
            workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main, using: handler),
            workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main, using: handler),
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: handler),
        ]
    }

    private func volumesChanged() {
        guard folders.refreshAvailability() else { return }
        if let folderURL, folders.root(containing: folderURL)?.isAvailable != true {
            closeFolder(forget: false)  // Reopened when the drive comes back.
        }
        if folderURL == nil { openSavedFolder() }
    }

    private static let selectedFolderKey = "SelectedFolderPath"

    func reloadFolder() {
        guard let folderURL else { return }
        openFolder(folderURL, keepState: true)
    }

    /// Shows the photos directly inside `url` (not in its subfolders).
    func openFolder(_ url: URL, keepState: Bool = false) {
        let url = SourceFolders.normalized(url)
        guard keepState || url != folderURL else { return }
        endCrop()
        flushSaves()
        UserDefaults.standard.set(url.path, forKey: Self.selectedFolderKey)

        let previousActiveID = keepState ? activeID : nil
        resetFolderState()
        folderURL = url
        isScanning = true
        viewMode = keepState ? viewMode : .grid

        Task {
            let entries = await Task.detached(priority: .userInitiated) { Self.scan(url) }.value
            guard folderURL == url else { return }
            await renderer.removeAll()
            photos = entries.map { Photo(url: $0.url, sidecarURL: $0.sidecar, settings: $0.settings) }
            photosByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
            isScanning = false

            if let first = previousActiveID.flatMap({ photosByID[$0] }) ?? photos.first {
                select(first)
            }
            // Embedded previews first; edited photos are re-queued for a rendered thumbnail.
            enqueueThumbnails(photos)
        }
    }

    private func closeFolder(forget: Bool) {
        endCrop()
        flushSaves()
        resetFolderState()
        folderURL = nil
        if forget { UserDefaults.standard.removeObject(forKey: Self.selectedFolderKey) }
    }

    private func resetFolderState() {
        isScanning = false
        photos = []
        photosByID = [:]
        selection = []
        activeID = nil
        anchorID = nil
        preview = nil
        undoStack = []
        redoStack = []
        thumbnailQueue = []
    }

    nonisolated private struct ScanEntry: Sendable {
        let url: URL
        let sidecar: URL
        let settings: EditSettings
    }

    nonisolated private static func scan(_ folder: URL) -> [ScanEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let files = contents
            .filter { PhotoFile.isSupported($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return files.map { file in
            let sidecar = Sidecar.url(for: file, in: files)
            return ScanEntry(url: file, sidecar: sidecar, settings: Sidecar.load(from: sidecar) ?? .default)
        }
    }

    // MARK: - Selection

    /// Handles a click on a thumbnail, honoring ⌘ and ⇧ modifiers.
    func click(_ photo: Photo, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(photo.id), selection.count > 1 {
                selection.remove(photo.id)
                if activeID == photo.id, let next = selectedPhotos.first {
                    setActive(next.id)
                }
            } else {
                selection.insert(photo.id)
                setActive(photo.id)
            }
            anchorID = photo.id
        } else if modifiers.contains(.shift),
                  let anchor = anchorID,
                  let from = photos.firstIndex(where: { $0.id == anchor }),
                  let to = photos.firstIndex(where: { $0.id == photo.id }) {
            selection = Set(photos[min(from, to)...max(from, to)].map(\.id))
            setActive(photo.id)
        } else {
            select(photo)
        }
    }

    func select(_ photo: Photo) {
        selection = [photo.id]
        anchorID = photo.id
        setActive(photo.id)
    }

    func open(_ photo: Photo) {
        if !selection.contains(photo.id) {
            select(photo)
        } else {
            setActive(photo.id)
        }
        viewMode = .loupe
    }

    func selectAll() {
        selection = Set(photos.map(\.id))
        if activeID == nil, let first = photos.first { setActive(first.id) }
    }

    /// Keeps only the active photo selected.
    func deselectAll() {
        selection = activeID.map { [$0] } ?? []
        anchorID = activeID
    }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }

    private func step(_ offset: Int) {
        guard !photos.isEmpty else { return }
        let index = activeIndex.map { $0 + offset } ?? 0
        guard photos.indices.contains(index) else { return }
        select(photos[index])
    }

    private func setActive(_ id: Photo.ID) {
        guard id != activeID else { return }
        endCrop()
        if interactiveStart != nil {
            // A slider drag spans the switch: record it for the photo it started on, then
            // keep tracking the drag for the new photo.
            endInteractiveEdit()
            if let photo = photosByID[id] { interactiveStart = (id, photo.settings) }
        }
        if zoom != nil {
            // Stay at 100% on the same part of the frame, e.g. to compare focus across a burst.
            zoom = ZoomState(photoID: id, focus: zoomCenter, anchor: CGPoint(x: 0.5, y: 0.5))
            zoomFullSize = nil
            detail = nil
            detailViewport = nil
        }
        activeID = id
        showOriginal = false
        if let photo = photosByID[id], photo.metadata == nil {
            enqueueThumbnails([photo], atFront: true)
        }
        requestPreview()
    }

    // MARK: - Editing

    /// Changes the active photo. Called continuously while a slider is dragged.
    func updateActive(_ change: (inout EditSettings) -> Void) {
        guard let photo = activePhoto else { return }
        let before = photo.settings
        var settings = before
        change(&settings)
        guard settings != before else { return }
        photo.settings = settings
        didChangeSettings(of: [photo])
        if interactiveStart == nil, !isCropping {
            pushUndo(EditRecord(name: "Edit", changes: [Change(id: photo.id, before: before, after: settings)]))
        }
    }

    func beginInteractiveEdit() {
        guard !isCropping, let photo = activePhoto else { return }
        interactiveStart = (photo.id, photo.settings)
    }

    func endInteractiveEdit() {
        defer { interactiveStart = nil }
        guard let start = interactiveStart, let photo = photosByID[start.id], photo.settings != start.settings else { return }
        pushUndo(EditRecord(name: "Edit", changes: [Change(id: photo.id, before: start.settings, after: photo.settings)]))
    }

    /// Applies new settings to several photos as one undoable action.
    private func apply(_ updates: [(Photo, EditSettings)], actionName: String) {
        let changes = updates
            .filter { $0.0.settings != $0.1 }
            .map { Change(id: $0.0.id, before: $0.0.settings, after: $0.1) }
        guard !changes.isEmpty else { return }
        for (photo, settings) in updates { photo.settings = settings }
        didChangeSettings(of: updates.map(\.0))
        pushUndo(EditRecord(name: actionName, changes: changes))
    }

    private func didChangeSettings(of changed: [Photo]) {
        for photo in changed {
            scheduleSave(photo)
            if photo.id == activeID {
                requestPreview(forThumbnail: true)
            } else {
                enqueueThumbnails([photo])
            }
        }
    }

    func resetAdjustments() {
        endCrop()
        apply(targetPhotos.map { ($0, EditSettings.default) }, actionName: "Reset Adjustments")
    }

    // MARK: - Copy and paste

    func copyAdjustments(groups: AdjustmentGroups? = nil) {
        guard let photo = activePhoto else { return }
        clipboard = photo.settings
        if let groups { clipboardGroups = groups }
    }

    var canPaste: Bool { clipboard != nil && activePhoto != nil }

    /// Single-key shortcuts are disabled while a sheet is up.
    var isShowingSheet: Bool { export.isPresented || isShowingCopyOptions }

    func pasteAdjustments(toSelected: Bool) {
        guard let clipboard else { return }
        endCrop()
        let targets = toSelected ? targetPhotos : (activePhoto.map { [$0] } ?? [])
        let groups = clipboardGroups
        let updates = targets.map { photo -> (Photo, EditSettings) in
            var settings = photo.settings.merging(groups, from: clipboard)
            if groups.contains(.geometry), let size = photo.geometrySize {
                settings.crop = CropGeometry.fitted(settings.crop, angle: settings.straighten, imageSize: size)
            }
            return (photo, settings)
        }
        apply(updates, actionName: toSelected ? "Paste to Selected" : "Paste Adjustments")
    }

    // MARK: - Undo

    private func pushUndo(_ record: EditRecord) {
        undoStack.append(record)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard canUndo, let record = undoStack.popLast() else { return }
        restore(record.changes.map { ($0.id, $0.before) })
        redoStack.append(record)
    }

    func redo() {
        guard canRedo, let record = redoStack.popLast() else { return }
        restore(record.changes.map { ($0.id, $0.after) })
        undoStack.append(record)
    }

    private func restore(_ values: [(Photo.ID, EditSettings)]) {
        let changed = values.compactMap { id, settings -> Photo? in
            guard let photo = photosByID[id] else { return nil }
            photo.settings = settings
            return photo
        }
        didChangeSettings(of: changed)
    }

    // MARK: - Crop

    func toggleCrop() {
        isCropping ? endCrop() : beginCrop()
    }

    func beginCrop() {
        guard let photo = activePhoto, !isCropping else { return }
        viewMode = .loupe
        exitZoom(refreshPreview: false)
        showOriginal = false
        cropSessionStart = photo.settings
        isCropping = true
        requestPreview()
    }

    /// Commits the crop session as one undoable action.
    func endCrop() {
        guard isCropping else { return }
        isCropping = false
        straightenBase = nil
        if let start = cropSessionStart, let photo = activePhoto, photo.settings != start {
            pushUndo(EditRecord(name: "Crop", changes: [Change(id: photo.id, before: start, after: photo.settings)]))
        }
        cropSessionStart = nil
        requestPreview()
    }

    func cancelCrop() {
        guard isCropping else { return }
        if let start = cropSessionStart {
            updateActive { $0 = start }
        }
        cropSessionStart = nil
        endCrop()
    }

    func setCrop(_ rect: CropRect) {
        updateActive { $0.crop = rect.rounded }
    }

    func resetCrop() {
        guard let photo = activePhoto, let size = photo.geometrySize else { return }
        updateActive { settings in
            settings.straighten = 0
            if let aspect = CropGeometry.pixelAspect(for: settings.aspectRatio, matching: .full, imageSize: size) {
                settings.crop = CropGeometry.largestRect(pixelAspect: aspect, angle: 0, imageSize: size).rounded
            } else {
                settings.crop = .full
            }
        }
    }

    func setAspectRatio(_ ratio: AspectRatio) {
        guard let photo = activePhoto, let size = photo.geometrySize else { return }
        updateActive { settings in
            settings.aspectRatio = ratio
            if let aspect = CropGeometry.pixelAspect(for: ratio, matching: settings.crop, imageSize: size) {
                settings.crop = CropGeometry.largestRect(pixelAspect: aspect, angle: settings.straighten, imageSize: size).rounded
            }
        }
    }

    /// Switches the crop between landscape and portrait.
    func rotateCropOrientation() {
        guard let photo = activePhoto, let size = photo.geometrySize else { return }
        updateActive { settings in
            let aspect = CropGeometry.pixelAspect(of: settings.crop, imageSize: size)
            settings.crop = CropGeometry.largestRect(pixelAspect: 1 / aspect, angle: settings.straighten, imageSize: size).rounded
        }
    }

    func beginStraighten() {
        straightenBase = activePhoto?.settings.crop
    }

    func endStraighten() {
        straightenBase = nil
    }

    func setStraighten(_ angle: Double) {
        guard let photo = activePhoto, let size = photo.geometrySize else { return }
        let base = straightenBase ?? photo.settings.crop
        let rounded = (angle * 100).rounded() / 100
        updateActive { settings in
            settings.straighten = rounded
            settings.crop = CropGeometry.fitted(base, angle: rounded, imageSize: size).rounded
        }
    }

    // MARK: - Preview rendering

    private var previewPixelSize: CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = screen.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
        return min(max(size, 1600), 3600)
    }

    /// Renders the active photo. Requests made while a render is running are coalesced.
    private func requestPreview(forThumbnail: Bool = false) {
        guard activePhoto != nil else {
            preview = nil
            return
        }
        if zoom != nil {
            // Keep the RAW decoder at full resolution while zoomed.
            previewStaleWhileZoomed = true
            requestDetail()
            return
        }
        guard viewMode == .loupe || forThumbnail else { return }
        renderPending = true
        renderForThumbnail = renderForThumbnail || forThumbnail
        guard renderTask == nil else { return }

        renderTask = Task {
            while renderPending {
                renderPending = false
                let wantsThumbnail = renderForThumbnail
                renderForThumbnail = false
                guard let photo = activePhoto, viewMode == .loupe || wantsThumbnail else { break }

                let original = showOriginal
                let geometry = !isCropping && !original
                let settings = original ? EditSettings.default : photo.settings
                let result = await renderer.render(
                    url: photo.url,
                    settings: settings,
                    geometry: geometry,
                    maxPixelSize: previewPixelSize,
                    makeThumbnail: geometry
                )

                guard let result else {
                    if photo.id == activeID, viewMode == .loupe {
                        preview = nil
                    }
                    continue
                }
                photo.imageSize = result.baseSize
                if let thumbnail = result.thumbnail, photo.settings == settings {
                    photo.thumbnail = thumbnail
                }
                if photo.id == activeID {
                    preview = PreviewImage(photoID: photo.id, image: result.image, hasGeometry: geometry)
                }
            }
            renderTask = nil
        }
    }

    // MARK: - Zoom

    /// Switches between fit-to-window and 100% (one image pixel per screen pixel). `focus` is
    /// the image point to zoom into and `anchor` where it should appear in the canvas, both
    /// normalized; the defaults zoom into the center.
    func toggleZoom(focus: CGPoint = CGPoint(x: 0.5, y: 0.5), anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        if zoom != nil {
            exitZoom()
            return
        }
        guard let photo = activePhoto, !isCropping else { return }
        viewMode = .loupe
        zoom = ZoomState(photoID: photo.id, focus: focus, anchor: anchor)
        zoomFullSize = nil
        detail = nil
        detailViewport = nil
        requestDetail()
    }

    func exitZoom(refreshPreview: Bool = true) {
        guard zoom != nil else { return }
        zoom = nil
        zoomFullSize = nil
        detail = nil
        detailViewport = nil
        if refreshPreview, previewStaleWhileZoomed {
            previewStaleWhileZoomed = false
            requestPreview(forThumbnail: true)
        }
    }

    /// Called as the zoomed view scrolls; `rect` is the visible area in full-resolution pixels.
    func setZoomViewport(_ rect: CGRect) {
        guard zoom != nil, let fullSize = zoomFullSize else { return }
        zoomCenter = CGPoint(
            x: min(max(rect.midX / fullSize.width, 0), 1),
            y: min(max(rect.midY / fullSize.height, 0), 1)
        )
        // Render a margin around the visible area so small pans don't reveal the soft base.
        let margin = rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25)
        let viewport = margin.integral.intersection(CGRect(origin: .zero, size: fullSize))
        if let detail, detail.photoID == activeID, detail.rect.contains(rect), detailViewport != nil {
            detailViewport = viewport
            return  // Visible area is already covered.
        }
        detailViewport = viewport
        requestDetail()
    }

    /// Renders the visible area at full resolution. Requests made while a render is running are coalesced.
    private func requestDetail() {
        detailPending = true
        guard detailTask == nil else { return }
        detailTask = Task {
            while detailPending {
                detailPending = false
                guard let zoom, let photo = activePhoto, photo.id == zoom.photoID else { break }
                let original = showOriginal
                let result = await renderer.renderDetail(
                    url: photo.url,
                    settings: original ? EditSettings.default : photo.settings,
                    geometry: !original,
                    rect: detailViewport
                )
                guard self.zoom?.photoID == photo.id, let result else { continue }
                zoomFullSize = result.fullSize
                if let image = result.image {
                    detail = DetailImage(photoID: photo.id, image: image, rect: result.rect)
                }
            }
            detailTask = nil
        }
    }

    // MARK: - Thumbnails

    private func enqueueThumbnails(_ list: [Photo], atFront: Bool = false) {
        let ids = list.map(\.id).filter { !thumbnailQueue.contains($0) }
        if atFront {
            thumbnailQueue.insert(contentsOf: ids, at: 0)
        } else {
            thumbnailQueue.append(contentsOf: ids)
        }
        runThumbnailQueue()
    }

    private func runThumbnailQueue() {
        guard thumbnailTask == nil, !thumbnailQueue.isEmpty else { return }
        thumbnailTask = Task {
            while !thumbnailQueue.isEmpty {
                let batch = thumbnailQueue.prefix(4).compactMap { photosByID[$0] }
                thumbnailQueue.removeFirst(min(4, thumbnailQueue.count))

                // Photos without a thumbnail get the fast embedded preview first.
                let jobs = batch.map { photo -> (Photo, EditSettings?) in
                    (photo, photo.isEdited && photo.thumbnail != nil ? photo.settings : nil)
                }
                // Embedded previews load in parallel. Rendered ones decode the whole RAW, which
                // doesn't get faster in parallel but uses much more memory, so they run one at a time.
                let embedded = jobs.filter { $0.1 == nil }.map { ($0.0, loadThumbnail(for: $0.0, renderedWith: nil)) }
                for (photo, task) in embedded {
                    setThumbnail(await task.value, for: photo, renderedWith: nil)
                }
                for case let (photo, settings?) in jobs {
                    setThumbnail(await loadThumbnail(for: photo, renderedWith: settings).value, for: photo, renderedWith: settings)
                }
            }
            thumbnailTask = nil
        }
    }

    /// Loads metadata if missing, and either the embedded preview or a render with `settings`.
    private func loadThumbnail(for photo: Photo, renderedWith settings: EditSettings?) -> Task<(CGImage?, PhotoMetadata?), Never> {
        let url = photo.url
        let needsMetadata = photo.metadata == nil
        return Task.detached(priority: .utility) {
            let metadata = needsMetadata ? PhotoMetadata.load(url: url) : nil
            let image = settings.map { Thumbnails.rendered(url: url, settings: $0) } ?? Thumbnails.embedded(url: url)
            return (image, metadata)
        }
    }

    private func setThumbnail(_ result: (CGImage?, PhotoMetadata?), for photo: Photo, renderedWith settings: EditSettings?) {
        let (image, metadata) = result
        if let metadata { photo.metadata = metadata }
        guard let image else { return }
        if let settings {
            // Drop stale renders; a newer request is already queued.
            if photo.settings == settings { photo.thumbnail = image }
        } else if !photo.isEdited || photo.thumbnail == nil {
            photo.thumbnail = image
            if photo.isEdited { enqueueThumbnails([photo]) }
        }
    }

    // MARK: - Saving

    private func scheduleSave(_ photo: Photo) {
        dirtyIDs.insert(photo.id)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushSaves()
        }
    }

    /// Writes pending sidecar files immediately.
    func flushSaves() {
        saveTask?.cancel()
        saveTask = nil
        for id in dirtyIDs {
            guard let photo = photosByID[id] else { continue }
            do {
                try Sidecar.save(photo.settings, to: photo.sidecarURL)
            } catch where !didReportSaveError {
                didReportSaveError = true
                alertMessage = "Could not save edits for \(photo.name): \(error.localizedDescription)"
            } catch {}
        }
        dirtyIDs.removeAll()
    }

    // MARK: - Export

    func exportTargets() {
        endCrop()
        flushSaves()
        export.present(jobs: targetPhotos.map { ExportJob(source: $0.url, settings: $0.settings) })
    }

    func revealActiveInFinder() {
        let urls = targetPhotos.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
