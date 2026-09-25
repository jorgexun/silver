import AppKit
import Observation

struct ExportFailure: Identifiable {
    let id = UUID()
    let fileName: String
    let message: String
}

struct ExportSummary {
    let folder: URL
    let exported: [URL]
    let failures: [ExportFailure]
    let wasCancelled: Bool
}

@Observable
final class ExportModel {
    enum Phase {
        case configuring
        case exporting(completed: Int, total: Int)
        case finished(ExportSummary)
    }

    var isPresented = false
    private(set) var phase: Phase = .configuring
    private(set) var jobs: [ExportJob] = []
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
    private(set) var outputFolder: URL?

    init() {
        let defaults = UserDefaults.standard
        quality = defaults.object(forKey: "ExportQuality") as? Double ?? 0.9
        includeMetadata = defaults.object(forKey: "ExportIncludeMetadata") as? Bool ?? true
        existingFilePolicy = defaults.string(forKey: "ExportExistingFilePolicy").flatMap { ExistingFilePolicy(rawValue: $0) } ?? .keepBoth
        outputFolder = Bookmarks.resolve(forKey: Bookmarks.exportFolderKey)
    }

    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    func present(jobs: [ExportJob]) {
        guard !jobs.isEmpty, !isExporting else { return }
        self.jobs = jobs
        phase = .configuring
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

    func start() {
        guard let folder = outputFolder, !jobs.isEmpty, !isExporting else { return }
        let jobs = self.jobs
        let options = ExportOptions(quality: quality, includeMetadata: includeMetadata, existingFilePolicy: existingFilePolicy)
        phase = .exporting(completed: 0, total: jobs.count)

        task = Task {
            var reserved = Set<String>()
            var exported: [URL] = []
            var failures: [ExportFailure] = []
            for (index, job) in jobs.enumerated() {
                if Task.isCancelled { break }
                let destination = Exporter.destination(for: job.source, in: folder, policy: options.existingFilePolicy, reserved: reserved)
                reserved.insert(destination.lastPathComponent.lowercased())
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Exporter.export(job, to: destination, options: options)
                    }.value
                    exported.append(destination)
                } catch {
                    failures.append(ExportFailure(fileName: job.source.lastPathComponent, message: error.localizedDescription))
                }
                phase = .exporting(completed: index + 1, total: jobs.count)
            }
            phase = .finished(ExportSummary(folder: folder, exported: exported, failures: failures, wasCancelled: Task.isCancelled))
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        guard !isExporting else { return }
        isPresented = false
    }

    func revealInFinder() {
        guard case .finished(let summary) = phase else { return }
        if summary.exported.isEmpty {
            NSWorkspace.shared.open(summary.folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(summary.exported)
        }
    }
}
