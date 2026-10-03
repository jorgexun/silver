import AppKit
import Observation

struct ExportFailure: Identifiable {
    let id = UUID()
    let fileName: String
    let message: String
}

/// What an export run did. A run takes in every export started before it ends.
struct ExportSummary: Identifiable {
    let id = UUID()
    var photos = 0
    /// The JPEG files saved to folders.
    var exported: [URL] = []
    /// How many photos were added to Photos, or nil when Photos wasn't a destination.
    var addedToPhotos: Int?
    var failures: [ExportFailure] = []
    var wasCancelled = false

    /// Every photo went where it should.
    var isClean: Bool { failures.isEmpty && !wasCancelled }

    var title: String {
        if wasCancelled { return "Export Stopped" }
        let problems = failures.count
        if problems > 0 { return problems == 1 ? "Exported with 1 Problem" : "Exported with \(problems) Problems" }
        return photos == 1 ? "Exported 1 Photo" : "Exported \(photos) Photos"
    }

    /// “12 JPEG files saved to Exports, 12 photos added to Photos.”
    var outcome: String {
        var parts: [String] = []
        if !exported.isEmpty || addedToPhotos == nil {
            let files = exported.count == 1 ? "1 JPEG file" : "\(exported.count) JPEG files"
            let folders = Set(exported.map { $0.deletingLastPathComponent().lastPathComponent })
            parts.append(folders.count == 1 ? "\(files) saved to \(folders.first!)" : "\(files) saved")
        }
        if let added = addedToPhotos {
            parts.append(added == 1 ? "1 photo added to Photos" : "\(added) photos added to Photos")
        }
        return parts.joined(separator: ", ") + "."
    }
}

/// Where an export run is.
struct ExportProgress {
    var completed: Int
    var total: Int
    /// The file being exported.
    var current: String?

    /// “Exporting 2 of 12”, counting the photo being exported.
    var label: String { "Exporting \(min(completed + 1, total)) of \(total)" }
    var fraction: Double { Double(completed) / Double(max(total, 1)) }
}

/// Export settings, and exports running in the background. The settings sheet only sets up an
/// export; starting one closes it, and the toolbar shows the progress, as in Photos and
/// Lightroom. Exports started while one runs are queued behind it.
@Observable
final class ExportModel {
    /// One press of Export: the photos with their settings when the sheet opened, and where
    /// they go.
    private struct Batch {
        let jobs: [ExportJob]
        let folder: URL?
        let toPhotos: Bool
        let options: ExportOptions
    }

    /// The settings sheet.
    var isPresented = false
    /// The photos the sheet would export.
    private(set) var jobs: [ExportJob] = []
    /// Thumbnails of the first few of them, for the sheet's header.
    private(set) var thumbnails: [CGImage] = []
    /// Set while the system asks for access to Photos.
    private(set) var isRequestingAccess = false

    /// Set while exporting. Stored apart from `progress`, so views that only show whether an
    /// export runs aren't updated for each photo.
    private(set) var isExporting = false
    private(set) var progress: ExportProgress?
    /// The last run, until it's dismissed or another starts. A clean result goes away by
    /// itself after a few seconds, one with problems once it has been looked at.
    private(set) var result: ExportSummary?
    /// The toolbar's popover with the progress or result. Closing it dismisses the result.
    var isShowingActivity = false {
        didSet { if !isShowingActivity, !isExporting { result = nil } }
    }
    private var queue: [Batch] = []
    private var summary = ExportSummary()
    private var task: Task<Void, Never>?

    var quality: Double {
        didSet { UserDefaults.standard.set(quality, forKey: "ExportQuality") }
    }
    var includeMetadata: Bool {
        didSet { UserDefaults.standard.set(includeMetadata, forKey: "ExportIncludeMetadata") }
    }
    var existingFilePolicy: ExistingFilePolicy {
        didSet { UserDefaults.standard.set(existingFilePolicy.rawValue, forKey: "ExportExistingFilePolicy") }
    }
    var exportsToFolder: Bool {
        didSet { UserDefaults.standard.set(exportsToFolder, forKey: "ExportToFolder") }
    }
    var addsToPhotos: Bool {
        didSet { UserDefaults.standard.set(addsToPhotos, forKey: "ExportToPhotos") }
    }
    /// Whether the user turned off Silver's access to Photos. Read when the sheet opens and
    /// after asking.
    private(set) var isPhotosAccessDenied = false
    private(set) var outputFolder: URL?
    /// Lowercased names of the files in `outputFolder`, for warning before an export that some
    /// names are taken. Read by `refreshExistingNames()`.
    private(set) var existingNames: Set<String> = []

    init() {
        let defaults = UserDefaults.standard
        quality = defaults.object(forKey: "ExportQuality") as? Double ?? 0.9
        includeMetadata = defaults.object(forKey: "ExportIncludeMetadata") as? Bool ?? true
        existingFilePolicy = defaults.string(forKey: "ExportExistingFilePolicy").flatMap { ExistingFilePolicy(rawValue: $0) } ?? .keepBoth
        exportsToFolder = defaults.object(forKey: "ExportToFolder") as? Bool ?? true
        addsToPhotos = defaults.object(forKey: "ExportToPhotos") as? Bool ?? false
        outputFolder = Bookmarks.resolve(forKey: Bookmarks.exportFolderKey)
    }

    var qualityPercent: Int { Int((quality * 100).rounded()) }

    /// At least one destination is on, and the folder is chosen if it's one of them.
    var canStart: Bool {
        !isRequestingAccess && (exportsToFolder ? outputFolder != nil : addsToPhotos)
    }

    func present(jobs: [ExportJob], thumbnails: [CGImage]) {
        guard !jobs.isEmpty else { return }
        if outputFolder == nil {
            // The saved folder may have been on a drive that is connected now.
            outputFolder = Bookmarks.resolve(forKey: Bookmarks.exportFolderKey)
        }
        self.jobs = jobs
        self.thumbnails = thumbnails
        isPhotosAccessDenied = PhotosImporter.isDenied
        isPresented = true
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for exported JPEG files."
        if let outputFolder { panel.directoryURL = outputFolder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder?.stopAccessingSecurityScopedResource()
        outputFolder = url
        Bookmarks.save(url, forKey: Bookmarks.exportFolderKey)
    }

    /// Closes the sheet and exports in the background. When adding to Photos, the system first
    /// asks for access, the first time; the sheet stays open if it's refused.
    func start() {
        guard canStart, !jobs.isEmpty else { return }
        let batch = Batch(
            jobs: jobs,
            folder: exportsToFolder ? outputFolder : nil,
            toPhotos: addsToPhotos,
            options: ExportOptions(quality: quality, includeMetadata: includeMetadata, existingFilePolicy: existingFilePolicy)
        )
        guard batch.toPhotos else { return enqueue(batch) }
        isRequestingAccess = true
        Task {
            let allowed = await PhotosImporter.requestAccess()
            isRequestingAccess = false
            isPhotosAccessDenied = !allowed
            // The sheet may have been cancelled while the system asked.
            if allowed && isPresented { enqueue(batch) }
        }
    }

    private func enqueue(_ batch: Batch) {
        isPresented = false
        queue.append(batch)
        if task == nil {
            summary = ExportSummary()
            result = nil
            isExporting = true
            progress = ExportProgress(completed: 0, total: 0)
            task = Task { await run() }
        }
        progress?.total += batch.jobs.count
    }

    private func run() async {
        while !queue.isEmpty, !Task.isCancelled {
            await export(queue.removeFirst())
        }
        queue.removeAll()
        summary.photos = progress?.completed ?? 0
        summary.wasCancelled = Task.isCancelled
        result = summary
        isExporting = false
        progress = nil
        task = nil
        if summary.isClean {
            let id = summary.id
            Task {
                try? await Task.sleep(for: .seconds(3))
                if result?.id == id, !isShowingActivity { result = nil }
            }
        }
        await refreshExistingNames()
    }

    private func export(_ batch: Batch) async {
        if batch.toPhotos, summary.addedToPhotos == nil { summary.addedToPhotos = 0 }

        // Without a folder, files are written to a temporary one and moved into Photos.
        let isTemporary = batch.folder == nil
        let folder = batch.folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        if isTemporary { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { if isTemporary { try? FileManager.default.removeItem(at: folder) } }
        // The temporary folder starts empty, so only names used in this batch are taken there.
        let policy = isTemporary ? .overwrite : batch.options.existingFilePolicy

        var reserved = Set<String>()
        // Photos go into Photos one after another, while the next ones render.
        var adding: Task<Void, Never>?
        var pending = batch.jobs[...]
        var running = 0

        await withTaskGroup(of: (name: String, result: Result<URL, Error>).self) { group in
            while true {
                // Starts photos while fewer than the export contexts are exporting.
                while !Task.isCancelled, running < Exporter.contexts.count, let job = pending.popFirst() {
                    let name = job.source.lastPathComponent
                    // Off the main actor, like the file checks. Names are reserved before the
                    // export starts, so photos exported at the same time don't take the same one.
                    let destination = await Task.detached(priority: .utility) { [reserved] in
                        Exporter.destination(for: job.source, in: folder, policy: policy, reserved: reserved)
                    }.value
                    reserved.insert(destination.lastPathComponent.lowercased())
                    running += 1
                    progress?.current = name
                    // Off the main actor too; the export contexts' GPU work runs at low priority.
                    group.addTask(priority: .utility) {
                        (name, Result { try Exporter.export(job, to: destination, options: batch.options) }.map { destination })
                    }
                }
                guard let finished = await group.next() else { break }
                running -= 1
                progress?.completed += 1
                switch finished.result {
                case .success(let destination):
                    if !isTemporary { summary.exported.append(destination) }
                    if batch.toPhotos {
                        adding = Task { [previous = adding] in
                            await previous?.value
                            await addToPhotos(destination, moving: isTemporary, name: finished.name)
                        }
                    }
                case .failure(let error):
                    summary.failures.append(ExportFailure(fileName: finished.name, message: error.localizedDescription))
                }
            }
        }
        // Before the temporary folder is removed.
        await adding?.value
    }

    private func addToPhotos(_ file: URL, moving: Bool, name: String) async {
        do {
            try await PhotosImporter.add(file, moving: moving)
            summary.addedToPhotos? += 1
        } catch {
            summary.failures.append(ExportFailure(fileName: name, message: "Not added to Photos: \(error.localizedDescription)"))
        }
    }

    /// Stops after the photos being exported, and drops the queued exports.
    func cancel() {
        task?.cancel()
    }

    /// Lists the output folder once, so checking a selection against it needs no file access.
    func refreshExistingNames() async {
        guard let folder = outputFolder else {
            existingNames = []
            return
        }
        let names = await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return Set(files.map { $0.lowercased() })
        }.value
        if outputFolder == folder { existingNames = names }
    }

    /// How many of `sources` would be exported to a name already in the output folder.
    func existingCount(for sources: [URL]) -> Int {
        sources.count { existingNames.contains(Exporter.fileName(for: $0).lowercased()) }
    }

    func revealInFinder() {
        guard let exported = result?.exported, !exported.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(exported)
    }
}
