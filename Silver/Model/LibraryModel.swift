import AppKit
import Observation
import Synchronization

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
struct DetailImage: Identifiable {
    let photoID: Photo.ID
    let image: CGImage
    /// Area covered, in full-resolution output pixels (top-left origin).
    let rect: CGRect

    var id: ObjectIdentifier { ObjectIdentifier(image) }
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
                loadPlaceholder()
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
    static let thumbnailSizes: ClosedRange<Double> = 110...380
    /// Columns the grid shows at its width and thumbnail size, for moving up and down by row.
    var gridColumns = 1
    var isInspectorPresented = true
    /// Closing the window keeps the app running; menu commands are off until it reopens, so
    /// they can't change photos out of sight.
    var isWindowOpen = true
    /// The inspector field a value is being typed into. Single-key shortcuts are off meanwhile,
    /// so the keys reach the field.
    var valueEditor: UUID?
    var isEditingValue: Bool { valueEditor != nil }
    var alertMessage: String?

    // MARK: Preview

    private(set) var preview: PreviewImage?
    /// The camera's embedded preview at screen size, shown until an unedited photo's first render.
    private(set) var placeholder: PreviewImage?
    private var placeholderTask: Task<Void, Never>?

    // MARK: Zoom

    private(set) var zoom: ZoomState?
    /// Full-resolution output size of the zoomed photo, once known.
    private(set) var zoomFullSize: CGSize?
    /// Rendered parts of the photo at 100%, drawn in order: after an edit the area around the
    /// visible one, then tiles uncovered by panning.
    private(set) var detail: [DetailImage] = []
    /// What `detail` was rendered with: settings, and whether it shows the original.
    private var detailRendering: (settings: EditSettings, original: Bool)?
    /// Visible area plus a margin, in full-resolution output pixels.
    private var detailViewport: CGRect?
    /// Visible area plus a margin, which panning fills in with tiles.
    private var detailCoverage: CGRect?
    /// `detailCoverage` extended in the direction of a pan, filled in after it.
    private var detailLead: CGRect?
    /// Last visible area and when it was reported, for the speed of a pan.
    private var lastZoomViewport: (rect: CGRect, time: TimeInterval)?
    /// Center of the visible area, normalized to the image; carried over to the next photo.
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    private var detailTask: Task<Void, Never>?
    private var detailPending = false
    /// Edits made while zoomed only re-render the visible detail; the fit preview catches up on exit.
    private var previewStaleWhileZoomed = false
    private let renderer = PreviewRenderer()
    private let previewQueue = PreviewQueue()
    /// Numbers preview requests, so a render that finishes late never replaces a newer preview.
    private var previewSequence = 0
    private var shownSequence = 0

    // MARK: Preview cache

    /// What a preview was rendered for. A cached preview is shown only for the same request.
    nonisolated struct PreviewKey: Equatable, Sendable {
        let settings: EditSettings
        let geometry: Bool
        /// Show Original: the photo's crop and straighten without its adjustments.
        let original: Bool
        let pixelSize: CGFloat
        let colorSpace: CGColorSpace
    }

    /// Recent previews, most recent last: photos just shown, and the ones next to the active
    /// photo, rendered ahead of time. One per photo and kind (with or without crop, or the
    /// original), so a slider drag replaces its entry instead of pushing the others out.
    private var previewCache: [(id: Photo.ID, key: PreviewKey, result: PreviewResult)] = []
    private static let previewCacheLimit = 6
    private var prefetchTask: Task<Void, Never>?
    /// The photo being prefetched; showing it waits for that instead of decoding it again.
    private var prefetching: (id: Photo.ID, key: PreviewKey, task: Task<PreviewResult?, Never>)?
    private var prefetchFailures: Set<Photo.ID> = []
    /// Direction of the last step through the photos, so the photo coming next is prefetched first.
    private var stepDirection = 1
    /// Set while photos are stepped through quickly, e.g. with an arrow key held down. Decoding
    /// then waits until the stepping pauses: a decode can't be stopped, so one for a photo already
    /// passed would hold up the photo the user stops at.
    private var isSteppingQuickly = false
    private var lastActivation = Date.distantPast
    private var deferredPreview: Task<Void, Never>?

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
    /// Photo and settings when the current slider drag began, and the undo name for the drag.
    private var interactiveStart: (id: Photo.ID, settings: EditSettings, name: String)?
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
        placeholder = nil
        previewCache = []
        prefetchFailures = []
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
            selectRange(from: from, to: to)
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
    func selectBelow() { step(gridColumns) }
    func selectAbove() { step(-gridColumns) }

    /// Like Shift-clicking the photo `offset` places from the active one.
    func extendSelection(by offset: Int) { step(offset, extend: true) }

    private func step(_ offset: Int, extend: Bool = false) {
        guard !photos.isEmpty else { return }
        let current = activeIndex
        var index = current.map { $0 + offset } ?? 0
        // A row step past the first or last row stops at the first or last photo, as in Photos.
        if abs(offset) > 1 { index = min(max(index, 0), photos.count - 1) }
        guard photos.indices.contains(index), index != current else { return }
        stepDirection = offset < 0 ? -1 : 1
        if extend, let anchor = anchorID.flatMap({ id in photos.firstIndex { $0.id == id } }) {
            selectRange(from: anchor, to: index)
        } else {
            select(photos[index])
        }
    }

    /// Selects the photos between two indices and makes the second active.
    private func selectRange(from: Int, to: Int) {
        selection = Set(photos[min(from, to)...max(from, to)].map(\.id))
        setActive(photos[to].id)
    }

    private func setActive(_ id: Photo.ID) {
        guard id != activeID else { return }
        endCrop()
        if let start = interactiveStart {
            // A slider drag spans the switch: record it for the photo it started on, then
            // keep tracking the drag for the new photo.
            endInteractiveEdit()
            if let photo = photosByID[id] { interactiveStart = (id, photo.settings, start.name) }
        }
        if zoom != nil {
            // Stay at 100% on the same part of the frame, e.g. to compare focus across a burst.
            zoom = ZoomState(photoID: id, focus: zoomCenter, anchor: CGPoint(x: 0.5, y: 0.5))
            zoomFullSize = nil
            clearDetail()
        }
        activeID = id
        showOriginal = false
        isSteppingQuickly = Date.now.timeIntervalSince(lastActivation) < 0.25
        lastActivation = .now
        guard let photo = photosByID[id] else { return }
        if photo.metadata == nil {
            enqueueThumbnails([photo], atFront: true)
        }
        // A photo rendered ahead of time shows right away, also as the base of the 100% view.
        if let cached = cachedPreview(for: photo, key: previewKey(for: photo)) {
            showPreview(cached, for: photo, geometry: true)
        } else {
            placeholderAttempt = nil
            loadPlaceholder()
        }
        requestPreview()
        schedulePrefetch()
    }

    // MARK: - Editing

    /// Changes the active photo. Called continuously while a slider is dragged.
    func updateActive(actionName: String = "Edit", _ change: (inout EditSettings) -> Void) {
        guard let photo = activePhoto else { return }
        let before = photo.settings
        var settings = before
        change(&settings)
        guard settings != before else { return }
        photo.settings = settings
        didChangeSettings(of: [photo])
        if interactiveStart == nil, !isCropping {
            pushUndo(EditRecord(name: actionName, changes: [Change(id: photo.id, before: before, after: settings)]))
        }
    }

    /// Resets some groups of the active photo's settings, e.g. from a section's reset button.
    func resetActive(_ groups: AdjustmentGroups, actionName: String) {
        updateActive(actionName: actionName) { $0 = $0.merging(groups, from: .default) }
    }

    /// Starts a slider drag, recorded as one undoable action named `actionName`, e.g. “Exposure”.
    func beginInteractiveEdit(_ actionName: String) {
        guard !isCropping, let photo = activePhoto else { return }
        interactiveStart = (photo.id, photo.settings, actionName)
    }

    func endInteractiveEdit() {
        defer { interactiveStart = nil }
        guard let start = interactiveStart, let photo = photosByID[start.id], photo.settings != start.settings else { return }
        pushUndo(EditRecord(name: start.name, changes: [Change(id: photo.id, before: start.settings, after: photo.settings)]))
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

    /// Resets `photos`, by default the selected photos.
    func resetAdjustments(of photos: [Photo]? = nil) {
        endCrop()
        apply((photos ?? targetPhotos).map { ($0, EditSettings.default) }, actionName: "Reset Adjustments")
    }

    // MARK: - Copy and paste

    /// Copies the settings of `photo`, by default the active photo.
    func copyAdjustments(from photo: Photo? = nil, groups: AdjustmentGroups? = nil) {
        guard let photo = photo ?? activePhoto else { return }
        clipboard = photo.settings
        if let groups { clipboardGroups = groups }
    }

    var canPaste: Bool { clipboard != nil && activePhoto != nil }

    var isShowingSheet: Bool { export.isPresented || isShowingCopyOptions }

    /// Single-key shortcuts (arrows, letters, Space) would take keys meant for a sheet or a field.
    var allowsSingleKeyShortcuts: Bool { !isShowingSheet && !isEditingValue }

    /// Photos a context-menu command acts on: the selection when `photo` is part of it, as in
    /// Finder, otherwise just `photo`.
    func contextTargets(for photo: Photo) -> [Photo] {
        selection.contains(photo.id) ? selectedPhotos : [photo]
    }

    /// Pastes onto `photos`, by default the selected photos, as Paste Edits does in Photos.
    func pasteAdjustments(to photos: [Photo]? = nil) {
        guard let clipboard else { return }
        endCrop()
        let targets = photos ?? targetPhotos
        let groups = clipboardGroups
        let updates = targets.map { photo -> (Photo, EditSettings) in
            var settings = photo.settings.merging(groups, from: clipboard)
            if groups.contains(.geometry), let size = photo.geometrySize {
                settings.crop = CropGeometry.fitted(settings.crop, angle: settings.straighten, imageSize: size)
            }
            return (photo, settings)
        }
        apply(updates, actionName: "Paste Adjustments")
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

    /// Switches the crop to landscape or portrait; square crops stay as they are.
    func setCropOrientation(portrait: Bool) {
        guard let photo = activePhoto, let size = photo.geometrySize else { return }
        guard CropGeometry.orientation(of: photo.settings.crop, imageSize: size) == (portrait ? .landscape : .portrait) else { return }
        rotateCropOrientation()
    }

    /// Whether the photo is being straightened, with the slider or by dragging on the canvas.
    var isStraightening: Bool { straightenBase != nil }

    func beginStraighten() {
        straightenBase = activePhoto?.settings.crop
    }

    func endStraighten() {
        straightenBase = nil
    }

    func setStraighten(_ angle: Double) {
        guard let photo = activePhoto, let size = photo.geometrySize else { return }
        let base = straightenBase ?? photo.settings.crop
        let rounded = (min(max(angle, -45), 45) * 100).rounded() / 100
        updateActive { settings in
            settings.straighten = rounded
            settings.crop = CropGeometry.fitted(base, angle: rounded, imageSize: size).rounded
        }
    }

    // MARK: - Preview rendering

    private var previewScreen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    private var previewPixelSize: CGFloat {
        let size = previewScreen.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
        return min(max(size, 1600), 3600)
    }

    /// Previews are rendered in the screen's color space, so Core Animation can show them as is.
    private var displayColorSpace: CGColorSpace {
        previewScreen?.colorSpace?.cgColorSpace ?? ImagePipeline.sRGB
    }

    /// Renders the active photo. A loop off the main actor renders the latest request, so a render
    /// starts as soon as an edit asks for it instead of after the main actor has updated the views
    /// for the edit, and one render follows another without waiting for the last to be shown.
    private func requestPreview(forThumbnail: Bool = false) {
        guard let photo = activePhoto else {
            preview = nil
            return
        }
        deferredPreview?.cancel()
        if isSteppingQuickly, preview?.photoID != photo.id, cachedPreview(for: photo, key: previewKey(for: photo)) == nil {
            // Shows the placeholder or thumbnail meanwhile.
            deferredPreview = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                isSteppingQuickly = false
                requestPreview(forThumbnail: forThumbnail)
                schedulePrefetch()
            }
            return
        }
        if zoom != nil {
            // Keep the RAW decoder at full resolution while zoomed.
            previewStaleWhileZoomed = true
            requestDetail()
            return
        }
        guard viewMode == .loupe || forThumbnail else { return }
        let original = showOriginal
        let geometry = !isCropping
        let key = previewKey(for: photo, original: original, geometry: geometry)
        previewSequence += 1
        if let cached = cachedPreview(for: photo, key: key) {
            shownSequence = previewSequence
            showPreview(cached, for: photo, geometry: geometry)
            guard viewMode == .loupe else { return }
            // The cached preview came from another context or an earlier render. Develop the
            // photo again while nothing waits on it, so Core Image has it cached and the first
            // step of a slider drag takes milliseconds instead of about 0.15 s.
            post(PreviewRequest(photoID: photo.id, url: photo.url, key: key, sequence: previewSequence, showsResult: false, prefetch: nil))
            return
        }
        // A photo being prefetched is shown when that's done, rather than decoded twice. With
        // other settings the render waits for the decode.
        if let prefetching, prefetching.id == photo.id, prefetching.key == key { return }
        let prefetch = prefetching.flatMap { $0.id == photo.id ? $0.task : nil }
        post(PreviewRequest(photoID: photo.id, url: photo.url, key: key, sequence: previewSequence, showsResult: true, prefetch: prefetch))
    }

    private func post(_ request: PreviewRequest) {
        guard previewQueue.post(request) else { return }
        let queue = previewQueue, renderer = renderer
        Task.detached(priority: .userInitiated) { [self] in
            while let request = queue.take() {
                _ = await request.prefetch?.value
                let result = await renderer.render(
                    url: request.url,
                    settings: request.key.settings,
                    geometry: request.key.geometry,
                    maxPixelSize: request.key.pixelSize,
                    colorSpace: request.key.colorSpace
                )
                if request.showsResult {
                    let isLast = !queue.hasNext
                    Task { @MainActor in didRender(request, result, isLast: isLast) }
                }
            }
            Task { @MainActor in schedulePrefetch() }
        }
    }

    private func didRender(_ request: PreviewRequest, _ result: PreviewResult?, isLast: Bool) {
        guard let photo = photosByID[request.photoID] else { return }
        let isNewest = photo.id == activeID && request.sequence > shownSequence
        guard let result else {
            if isNewest, viewMode == .loupe { preview = nil }
            return
        }
        storePreview(result, for: photo, key: request.key)
        if photo.imageSize != result.baseSize { photo.imageSize = result.baseSize }
        if isNewest {
            shownSequence = request.sequence
            showPreview(result, for: photo, geometry: request.key.geometry)
        }
        // Once a slider drag pauses.
        if isLast, request.key.geometry, !request.key.original {
            scheduleThumbnailRefresh(for: photo, settings: request.key.settings)
        }
    }

    private var thumbnailRefreshes: [Photo.ID: Task<Void, Never>] = [:]

    /// Refreshes a thumbnail from the preview once edits pause, not between the steps of a slider
    /// drag: the downscale takes about 30 ms of GPU time that the next step would wait for.
    private func scheduleThumbnailRefresh(for photo: Photo, settings: EditSettings) {
        thumbnailRefreshes[photo.id]?.cancel()
        thumbnailRefreshes[photo.id] = Task {
            repeat {
                try? await Task.sleep(for: .milliseconds(300))
            } while !Task.isCancelled && previewQueue.isRunning
            defer { if !Task.isCancelled { thumbnailRefreshes[photo.id] = nil } }
            guard !Task.isCancelled, photo.settings == settings,
                  let thumbnail = await renderer.thumbnail(url: photo.url, settings: settings),
                  photo.settings == settings
            else { return }
            photo.thumbnail = thumbnail
        }
    }

    private func showPreview(_ result: PreviewResult, for photo: Photo, geometry: Bool) {
        guard preview?.photoID != photo.id || preview?.image !== result.image else { return }
        preview = PreviewImage(photoID: photo.id, image: result.image, hasGeometry: geometry)
        if placeholder?.photoID == photo.id { placeholder = nil }
    }

    // MARK: - Preview cache and prefetching

    private func previewKey(for photo: Photo, original: Bool = false, geometry: Bool = true) -> PreviewKey {
        PreviewKey(
            settings: original ? photo.settings.original : photo.settings,
            geometry: geometry,
            original: original,
            pixelSize: previewPixelSize,
            colorSpace: displayColorSpace
        )
    }

    private func cachedPreview(for photo: Photo, key: PreviewKey) -> PreviewResult? {
        previewCache.last { $0.id == photo.id && $0.key == key }?.result
    }

    private func storePreview(_ result: PreviewResult, for photo: Photo, key: PreviewKey) {
        previewCache.removeAll { $0.id == photo.id && $0.key.geometry == key.geometry && $0.key.original == key.original }
        previewCache.append((photo.id, key, result))
        if previewCache.count > Self.previewCacheLimit { previewCache.removeFirst() }
    }

    /// Photos worth rendering ahead of time: in the loupe the ones next to the active photo, the
    /// one coming next first; in the grid the active photo, which Space or a double-click opens.
    private var prefetchCandidates: [Photo] {
        guard let index = activeIndex, !isCropping else { return [] }
        let indices = viewMode == .grid ? [index] : [index + stepDirection, index - stepDirection]
        return indices.filter { photos.indices.contains($0) }.map { photos[$0] }
    }

    /// The next photo to prefetch, once the active photo has been rendered.
    private func nextPrefetch() -> Photo? {
        guard !previewQueue.isRunning, detailTask == nil, !isSteppingQuickly else { return nil }
        return prefetchCandidates.first { photo in
            !prefetchFailures.contains(photo.id) && cachedPreview(for: photo, key: previewKey(for: photo)) == nil
        }
    }

    /// Renders the photos the user is likely to look at next, one at a time, in the background.
    /// Decoding a RAW file takes most of the time to open it, so after this the photo shows at once
    /// and its first edit only waits for the GPU (about 0.15 s instead of 0.8 s for M11 files).
    private func schedulePrefetch() {
        guard prefetchTask == nil, nextPrefetch() != nil else { return }
        prefetchTask = Task {
            while let photo = nextPrefetch() {
                if viewMode == .grid {
                    // Let the selection settle, so moving through the grid doesn't decode every photo.
                    try? await Task.sleep(for: .milliseconds(300))
                    guard nextPrefetch() === photo else { continue }
                }
                let key = previewKey(for: photo)
                let renderer = renderer
                let task = Task {
                    await renderer.prefetch(url: photo.url, settings: key.settings, maxPixelSize: key.pixelSize, colorSpace: key.colorSpace)
                }
                prefetching = (photo.id, key, task)
                let result = await task.value
                prefetching = nil
                // The folder may have changed meanwhile.
                guard photosByID[photo.id] === photo else { continue }
                if let result {
                    storePreview(result, for: photo, key: key)
                    if photo.imageSize != result.baseSize { photo.imageSize = result.baseSize }
                    // Shown from the cache now, if it's the photo waiting for it.
                    if photo.id == activeID { requestPreview() }
                } else {
                    prefetchFailures.insert(photo.id)
                    if photo.id == activeID { requestPreview() }
                }
            }
            prefetchTask = nil
        }
    }

    /// Shows the camera's embedded preview of an unedited RAW photo until it has been rendered,
    /// instead of the small thumbnail. Edited photos keep their thumbnail, which shows the edits.
    /// One loads at a time; moving on through the photos meanwhile skips the ones passed.
    private func loadPlaceholder() {
        if placeholder?.photoID != activeID { placeholder = nil }
        guard placeholderTask == nil else { return }
        placeholderTask = Task {
            // A photo without an embedded preview is tried once.
            while let photo = placeholderCandidate(), photo.id != placeholderAttempt {
                placeholderAttempt = photo.id
                let url = photo.url, pixelSize = previewPixelSize, colorSpace = displayColorSpace
                let image = await Task.detached(priority: .userInitiated) {
                    Thumbnails.screenPreview(url: url, maxPixelSize: pixelSize, colorSpace: colorSpace)
                }.value
                if let image, placeholderCandidate() === photo {
                    placeholder = PreviewImage(photoID: photo.id, image: image, hasGeometry: true)
                }
            }
            placeholderTask = nil
        }
    }

    private var placeholderAttempt: Photo.ID?

    private func placeholderCandidate() -> Photo? {
        guard viewMode == .loupe, let photo = activePhoto, photo.isRaw, !photo.isEdited,
              preview?.photoID != photo.id, placeholder?.photoID != photo.id
        else { return nil }
        return photo
    }

    // MARK: - Viewing

    /// Space: opens the active photo from the grid, or goes back to the grid, as in Photos.
    func toggleLoupe() {
        viewMode = viewMode == .grid ? .loupe : .grid
    }

    /// When `\` turned the original on; see `endOriginalPeek()`.
    private var originalKeyDown: Date?

    /// Shows or hides the original. A key held down instead shows it only until it's released,
    /// like M in Photos.
    func toggleOriginal() {
        showOriginal.toggle()
        originalKeyDown = showOriginal && NSApp.currentEvent?.type == .keyDown ? .now : nil
    }

    /// Called when `\` is released: after a hold rather than a tap, goes back to the edited photo.
    func endOriginalPeek() {
        guard let start = originalKeyDown else { return }
        originalKeyDown = nil
        if showOriginal, Date.now.timeIntervalSince(start) > 0.35 { showOriginal = false }
    }

    var canZoomIn: Bool {
        viewMode == .grid ? thumbnailSize < Self.thumbnailSizes.upperBound : zoom == nil && activePhoto != nil && !isCropping
    }

    var canZoomOut: Bool {
        viewMode == .grid ? thumbnailSize > Self.thumbnailSizes.lowerBound : zoom != nil
    }

    /// ⌘+: larger thumbnails in the grid, 100% in the loupe.
    func zoomIn() {
        if viewMode == .grid {
            thumbnailSize = min(thumbnailSize * 1.25, Self.thumbnailSizes.upperBound)
        } else if zoom == nil {
            toggleZoom()
        }
    }

    /// ⌘−: smaller thumbnails in the grid, fit in the loupe.
    func zoomOut() {
        if viewMode == .grid {
            thumbnailSize = max(thumbnailSize / 1.25, Self.thumbnailSizes.lowerBound)
        } else {
            exitZoom()
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
        clearDetail()
        requestDetail()
    }

    func exitZoom(refreshPreview: Bool = true) {
        guard zoom != nil else { return }
        zoom = nil
        zoomFullSize = nil
        clearDetail()
        if refreshPreview, previewStaleWhileZoomed {
            previewStaleWhileZoomed = false
            requestPreview(forThumbnail: true)
        }
    }

    private func clearDetail() {
        detail = []
        detailRendering = nil
        detailViewport = nil
        detailCoverage = nil
        detailLead = nil
        lastZoomViewport = nil
    }

    /// Called as the zoomed view scrolls; `rect` is the visible area in full-resolution pixels.
    func setZoomViewport(_ rect: CGRect) {
        guard zoom != nil, let fullSize = zoomFullSize else { return }
        zoomCenter = CGPoint(
            x: min(max(rect.midX / fullSize.width, 0), 1),
            y: min(max(rect.midY / fullSize.height, 0), 1)
        )
        let bounds = CGRect(origin: .zero, size: fullSize)
        // After an edit, the area around the visible one is rendered in one go, up to 256 px
        // around it but within Core Image's cache budget (see "100% zoom" in CLAUDE.md).
        let budget: CGFloat = 14_000_000
        let sum = rect.width + rect.height
        // Solves (width + 2 inset) × (height + 2 inset) = budget.
        let fit = (-sum + (sum * sum - 4 * (rect.width * rect.height - budget)).squareRoot()) / 4
        let inset = min(max(fit, 0), 256)
        detailViewport = rect.insetBy(dx: -inset, dy: -inset).integral.intersection(bounds)
        // Panning renders the tiles that reach into this margin first, then those where the pan
        // is heading: as far as it goes in 0.15 s, up to two tiles.
        let coverage = rect.insetBy(dx: -256, dy: -256).integral
        let now = ProcessInfo.processInfo.systemUptime
        var lead = coverage
        if let last = lastZoomViewport, now - last.time < 0.1 {
            let elapsed = max(now - last.time, 0.004)
            let reach = Self.detailTileSize * 2
            let dx = min(max((rect.midX - last.rect.midX) / elapsed * 0.15, -reach), reach)
            let dy = min(max((rect.midY - last.rect.midY) / elapsed * 0.15, -reach), reach)
            lead = lead.union(lead.offsetBy(dx: dx, dy: dy))
        }
        lastZoomViewport = (rect, now)
        detailCoverage = coverage.intersection(bounds)
        detailLead = lead.intersection(bounds)
        if detailTask == nil, isDetailCurrent, missingDetailTiles(in: detailLead).isEmpty { return }
        requestDetail()
    }

    /// Edge length of the tiles panning renders. A column of them on a 5K display renders in
    /// about 15 ms, where re-rendering the whole area would take about 80 ms.
    private static let detailTileSize: CGFloat = 512

    /// Whether `detail` shows the active photo with its current settings.
    private var isDetailCurrent: Bool {
        guard let photo = activePhoto, let rendering = detailRendering, detail.first?.photoID == photo.id else { return false }
        return rendering.original == showOriginal && rendering.settings == (showOriginal ? photo.settings.original : photo.settings)
    }

    /// Tiles whose part inside `coverage` the rendered parts don't cover, merged into rows and then
    /// into columns, so a pan renders the strip it uncovers as one or a few rectangles.
    private func missingDetailTiles(in coverage: CGRect?) -> [CGRect] {
        guard let coverage, let fullSize = zoomFullSize, !coverage.isEmpty else { return [] }
        let tile = Self.detailTileSize
        let bounds = CGRect(origin: .zero, size: fullSize)
        let columns = Int((coverage.minX / tile).rounded(.down))...Int((coverage.maxX / tile).rounded(.up)) - 1
        let rows = Int((coverage.minY / tile).rounded(.down))...Int((coverage.maxY / tile).rounded(.up)) - 1
        var runs: [CGRect] = []
        for row in rows {
            var run: CGRect?
            for column in columns {
                let rect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile).intersection(bounds)
                let needed = rect.intersection(coverage)
                if needed.isEmpty || Self.isCovered(needed, by: detail.map(\.rect)[...]) {
                    if let finished = run { runs.append(finished) }
                    run = nil
                } else {
                    run = run.map { $0.union(rect) } ?? rect
                }
            }
            if let run { runs.append(run) }
        }
        // Stack runs that span the same columns in consecutive rows.
        var merged: [CGRect] = []
        for run in runs {
            if let index = merged.lastIndex(where: { $0.minX == run.minX && $0.maxX == run.maxX && $0.maxY == run.minY }) {
                merged[index] = merged[index].union(run)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// Whether the union of `pieces` covers `rect`.
    private static func isCovered(_ rect: CGRect, by pieces: ArraySlice<CGRect>) -> Bool {
        guard let piece = pieces.first(where: { $0.intersects(rect) }) else { return false }
        let overlap = rect.intersection(piece)
        guard overlap.width * overlap.height > 0 else { return false }
        let rest = pieces.drop { $0 != piece }.dropFirst()
        // The parts of `rect` left of, right of, above and below the overlap.
        let remainders = [
            CGRect(x: rect.minX, y: rect.minY, width: overlap.minX - rect.minX, height: rect.height),
            CGRect(x: overlap.maxX, y: rect.minY, width: rect.maxX - overlap.maxX, height: rect.height),
            CGRect(x: overlap.minX, y: rect.minY, width: overlap.width, height: overlap.minY - rect.minY),
            CGRect(x: overlap.minX, y: overlap.maxY, width: overlap.width, height: rect.maxY - overlap.maxY),
        ]
        return remainders.allSatisfy { $0.width <= 0 || $0.height <= 0 || isCovered($0, by: rest) }
    }

    /// Renders the visible area at full resolution. Requests made while a render is running are coalesced.
    private func requestDetail() {
        detailPending = true
        guard detailTask == nil else { return }
        detailTask = Task {
            while detailPending {
                detailPending = false
                guard let zoom, let photo = activePhoto, photo.id == zoom.photoID else { break }
                if let prefetching, prefetching.id == photo.id {
                    // Already being decoded; wait for that rather than decoding it twice.
                    _ = await prefetching.task.value
                }
                let original = showOriginal
                let settings = original ? photo.settings.original : photo.settings
                // An edit re-renders everything shown in one go, which Core Image can cache for
                // the next step of a slider drag; a pan adds the tiles it uncovers.
                let isPan = isDetailCurrent
                let rects: [CGRect]
                if isPan {
                    let near = missingDetailTiles(in: detailCoverage)
                    rects = near.isEmpty ? missingDetailTiles(in: detailLead) : near
                    if rects.isEmpty { continue }
                } else {
                    rects = detailViewport.map { [$0] } ?? []  // None yet: only get the size.
                }
                let result = await renderer.renderDetail(
                    url: photo.url,
                    settings: settings,
                    rects: rects,
                    colorSpace: displayColorSpace
                )
                guard self.zoom?.photoID == photo.id, let result else { continue }
                if zoomFullSize != result.fullSize { zoomFullSize = result.fullSize }
                guard !result.pieces.isEmpty else { continue }
                let pieces = result.pieces.map { DetailImage(photoID: photo.id, image: $0.image, rect: $0.rect) }
                if isPan {
                    // After an edit meanwhile, the pending request renders everything again.
                    guard isDetailCurrent else { continue }
                    detail = prunedDetail(detail + pieces)
                    // Then the tiles ahead of the pan, unless something newer is waiting.
                    if !detailPending, !missingDetailTiles(in: detailLead).isEmpty { detailPending = true }
                } else {
                    // Tiles around it are left to the next pan: rendering them now would hold up
                    // the next step of a slider drag and push this area out of Core Image's cache.
                    detail = pieces
                    detailRendering = (settings, original)
                }
            }
            detailTask = nil
            schedulePrefetch()
        }
    }

    /// Drops rendered parts far from the visible area, keeping at most about 40 MP (160 MB).
    private func prunedDetail(_ pieces: [DetailImage]) -> [DetailImage] {
        guard let coverage = detailLead else { return pieces }
        let center = CGPoint(x: coverage.midX, y: coverage.midY)
        func distance(_ piece: DetailImage) -> CGFloat { hypot(piece.rect.midX - center.x, piece.rect.midY - center.y) }
        var kept = pieces.filter { $0.rect.intersects(coverage) }
        var area = kept.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        while area > 40_000_000, let farthest = kept.indices.max(by: { distance(kept[$0]) < distance(kept[$1]) }) {
            area -= kept[farthest].rect.width * kept[farthest].rect.height
            kept.remove(at: farthest)
        }
        return kept
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

    /// Exports `photos`, by default the selected photos.
    func exportPhotos(_ photos: [Photo]? = nil) {
        endCrop()
        flushSaves()
        export.present(jobs: (photos ?? targetPhotos).map { ExportJob(source: $0.url, settings: $0.settings) })
    }

    func revealActiveInFinder() {
        let urls = targetPhotos.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// A preview render for `LibraryModel`.
nonisolated struct PreviewRequest: Sendable {
    let photoID: Photo.ID
    let url: URL
    let key: LibraryModel.PreviewKey
    let sequence: Int
    /// False when rendering only so that Core Image caches the photo.
    let showsResult: Bool
    /// A prefetch of the photo still running, which has the decoded photo.
    let prefetch: Task<PreviewResult?, Never>?
}

/// The latest preview request, for the render loop. Requests posted while one is rendering
/// replace each other, so the loop always goes on with the newest.
nonisolated final class PreviewQueue: Sendable {
    private let state = Mutex<(next: PreviewRequest?, isRunning: Bool)>((nil, false))

    /// Returns true when no loop is running, and the caller must start one.
    func post(_ request: PreviewRequest) -> Bool {
        state.withLock { state in
            state.next = request
            defer { state.isRunning = true }
            return !state.isRunning
        }
    }

    /// The next request, or nil once there's none, which ends the loop.
    func take() -> PreviewRequest? {
        state.withLock { state in
            defer { state.next = nil }
            if state.next == nil { state.isRunning = false }
            return state.next
        }
    }

    var hasNext: Bool { state.withLock { $0.next != nil } }
    var isRunning: Bool { state.withLock { $0.isRunning } }
}
