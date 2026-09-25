import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = LibraryModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.restoreSession()
    }

    func applicationWillTerminate(_ notification: Notification) {
        library.flushSaves()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SilverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Silver", id: "main") {
            ContentView()
                .environment(appDelegate.library)
                .frame(minWidth: 1000, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1400, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            SilverCommands(library: appDelegate.library)
        }
    }
}

struct SilverCommands: Commands {
    let library: LibraryModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") { library.presentAddFolderPanel() }
                .keyboardShortcut("o")
            Button("Reload Folder") {
                if let url = library.folderURL, let node = library.folders.rows.first(where: { $0.node.url == url })?.node {
                    library.folders.refresh(node)
                }
                library.reloadFolder()
            }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(library.folderURL == nil)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Export JPEG…") { library.exportTargets() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(library.targetPhotos.isEmpty)
            Button("Show in Finder") { library.revealActiveInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(library.targetPhotos.isEmpty)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(library.undoActionName.map { "Undo \($0)" } ?? "Undo") { library.undo() }
                .keyboardShortcut("z")
                .disabled(!library.canUndo)
            Button(library.redoActionName.map { "Redo \($0)" } ?? "Redo") { library.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!library.canRedo)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Copy Adjustments") { library.copyAdjustments() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(library.activePhoto == nil)
            Button("Copy Adjustments…") { library.isShowingCopyOptions = true }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(library.activePhoto == nil)
            Button("Paste Adjustments") { library.pasteAdjustments(toSelected: false) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!library.canPaste)
            Button("Paste to Selected") { library.pasteAdjustments(toSelected: true) }
                .keyboardShortcut("v", modifiers: [.command, .shift, .option])
                .disabled(!library.canPaste || library.selection.count < 1)
            Divider()
            Button("Select All") { library.selectAll() }
                .keyboardShortcut("a")
                .disabled(library.photos.isEmpty)
            Button("Deselect All") { library.deselectAll() }
                .keyboardShortcut("d")
                .disabled(library.selection.count < 2)
        }

        CommandMenu("Photo") {
            Button("Previous Photo") { library.selectPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(library.photos.isEmpty)
            Button("Next Photo") { library.selectNext() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(library.photos.isEmpty)
            Divider()
            Button("Crop & Straighten") { library.toggleCrop() }
                .keyboardShortcut("r", modifiers: [])
                .disabled(library.activePhoto == nil)
            Button("Show Original") { library.showOriginal.toggle() }
                .keyboardShortcut("\\", modifiers: [])
                .disabled(library.activePhoto == nil || library.isCropping || library.viewMode != .loupe)
            Divider()
            Button("Reset Adjustments") { library.resetAdjustments() }
                .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                .disabled(library.targetPhotos.isEmpty)
        }

        CommandGroup(before: .sidebar) {
            Button("Grid") { library.viewMode = .grid }
                .keyboardShortcut("g", modifiers: [])
                .disabled(library.photos.isEmpty)
            Button("Loupe") { library.viewMode = .loupe }
                .keyboardShortcut("e", modifiers: [])
                .disabled(library.activePhoto == nil)
            Button(library.isInspectorPresented ? "Hide Adjustments" : "Show Adjustments") {
                library.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}
