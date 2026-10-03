import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = LibraryModel()
    private var keyUpMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.restoreSession()
        Task.detached(priority: .background) { ThumbnailCache.prune() }
        // Menu commands only see key presses; releasing a held \ ends a look at the original.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [library] event in
            if event.charactersIgnoringModifiers == "\\" { library.endOriginalPeek() }
            return event
        }
    }

    /// Quitting stops an export, so it asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let progress = library.export.progress else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Silver is exporting photos."
        alert.informativeText = "\(progress.completed) of \(progress.total) are done. If you quit now, the rest aren’t exported."
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        library.flushSaves()
    }

    /// Closing the window keeps the app running, as is usual on the Mac. SwiftUI would otherwise
    /// quit an app whose only scene is a `Window`.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        let targetPhotos = library.targetPhotos
        let targets = targetPhotos.count
        let singleKeys = library.allowsSingleKeyShortcuts
        let noWindow = !library.isWindowOpen

        CommandGroup(replacing: .newItem) {
            Group {
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
            .disabled(noWindow)
        }
        CommandGroup(after: .newItem) {
            Group {
                Divider()
                Button(targets > 1 ? "Export \(targets) Photos…" : "Export Photo…") { library.exportPhotos() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(targets == 0)
                Button("Show in Finder") { library.revealActiveInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(targets == 0)
                Divider()
                // No confirmation, as in Lightroom: Finder's Put Back restores the photos.
                Button(targets > 1 ? "Move \(targets) Photos to Trash" : "Move to Trash") { library.moveToTrash() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(targets == 0 || library.isCropping || !singleKeys)
            }
            .disabled(noWindow)
        }

        CommandGroup(replacing: .undoRedo) {
            Group {
                Button(library.undoActionName.map { "Undo \($0)" } ?? "Undo") { library.undo() }
                    .keyboardShortcut("z")
                    .disabled(!library.canUndo || library.isEditingValue)
                Button(library.redoActionName.map { "Redo \($0)" } ?? "Redo") { library.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!library.canRedo || library.isEditingValue)
            }
            .disabled(noWindow)
        }

        CommandGroup(replacing: .pasteboard) {
            Group {
                // While a value is being typed, ⌘C and ⌘V copy and paste its text instead.
                if library.isEditingValue {
                    Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                        .keyboardShortcut("c")
                    Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                        .keyboardShortcut("v")
                } else {
                    Button("Copy Adjustments") { library.copyAdjustments() }
                        .keyboardShortcut("c")
                        .disabled(library.activePhoto == nil)
                    Button("Copy Adjustments…") { library.isShowingCopyOptions = true }
                        .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                        .disabled(library.activePhoto == nil)
                    // Pastes onto every selected photo, as Paste Edits does in Photos.
                    Button(targets > 1 ? "Paste Adjustments to \(targets) Photos" : "Paste Adjustments") { library.pasteAdjustments() }
                        .keyboardShortcut("v")
                        .disabled(!library.canPaste || library.isCropping)
                }
                Divider()
                Button("Select All") { library.selectAll() }
                    .keyboardShortcut("a")
                    .disabled(library.photos.isEmpty || library.isEditingValue)
                Button("Deselect All") { library.deselectAll() }
                    .keyboardShortcut("d")
                    .disabled(!library.canDeselectAll || library.isEditingValue)
                Menu("Extend Selection") {
                    Button("To Previous Photo") { library.extendSelection(by: -1) }
                        .keyboardShortcut(.leftArrow, modifiers: .shift)
                        .disabled(!singleKeys)
                    Button("To Next Photo") { library.extendSelection(by: 1) }
                        .keyboardShortcut(.rightArrow, modifiers: .shift)
                        .disabled(!singleKeys)
                    Button("To Photo Above") { library.extendSelection(by: -library.gridColumns) }
                        .keyboardShortcut(.upArrow, modifiers: .shift)
                        .disabled(!singleKeys || library.viewMode != .grid)
                    Button("To Photo Below") { library.extendSelection(by: library.gridColumns) }
                        .keyboardShortcut(.downArrow, modifiers: .shift)
                        .disabled(!singleKeys || library.viewMode != .grid)
                }
                .disabled(library.photos.isEmpty)
            }
            .disabled(noWindow)
        }

        CommandMenu("Photo") {
            Group {
                Button("Previous Photo") { library.selectPrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(library.photos.isEmpty || !singleKeys)
                Button("Next Photo") { library.selectNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(library.photos.isEmpty || !singleKeys)
                Button("Photo Above") { library.selectAbove() }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(library.photos.isEmpty || library.viewMode != .grid || !singleKeys)
                Button("Photo Below") { library.selectBelow() }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(library.photos.isEmpty || library.viewMode != .grid || !singleKeys)
                Divider()
                Button("Crop & Straighten") { ignoringRepeats { library.toggleCrop() } }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(library.activePhoto == nil || !singleKeys)
                Button("Switch Crop Orientation") { ignoringRepeats { library.rotateCropOrientation() } }
                    .keyboardShortcut("x", modifiers: [])
                    .disabled(!library.isCropping || !singleKeys)
                Button("Show Original") { ignoringRepeats { library.toggleOriginal() } }
                    .keyboardShortcut("\\", modifiers: [])
                    .disabled(library.activePhoto == nil || library.isCropping || library.viewMode != .loupe || !singleKeys)
                Divider()
                Button(targets > 1 ? "Reset \(targets) Photos" : "Reset Adjustments") { library.resetAdjustments() }
                    .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                    .disabled(targetPhotos.allSatisfy { !$0.isEdited } || library.isCropping)
            }
            .disabled(noWindow)
        }

        CommandGroup(before: .sidebar) {
            Group {
                Button("Grid") { library.viewMode = .grid }
                    .keyboardShortcut("g", modifiers: [])
                    .disabled(library.photos.isEmpty || !singleKeys)
                // With nothing selected, these open the photo last selected.
                Button("Loupe") { library.viewMode = .loupe }
                    .keyboardShortcut("e", modifiers: [])
                    .disabled(library.photos.isEmpty || !singleKeys)
                Button(library.viewMode == .grid ? "Open Photo" : "Back to Grid") { ignoringRepeats { library.toggleLoupe() } }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(library.photos.isEmpty || library.isCropping || !singleKeys)
                Divider()
                Button(library.zoom == nil ? "Zoom to 100%" : "Zoom to Fit") { ignoringRepeats { library.toggleZoom() } }
                    .keyboardShortcut("z", modifiers: [])
                    .disabled(library.activePhoto == nil || library.isCropping || !singleKeys)
                Button("Zoom In") { library.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(!library.canZoomIn || library.isShowingSheet)
                Button("Zoom Out") { library.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(!library.canZoomOut || library.isShowingSheet)
                Divider()
                Button(library.isInspectorPresented ? "Hide Adjustments" : "Show Adjustments") {
                    library.isInspectorPresented.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
            .disabled(noWindow)
        }
    }

    /// Runs `action` for a key press but not for its auto-repeats, so holding the key of a toggle
    /// doesn't flip it back and forth.
    private func ignoringRepeats(_ action: () -> Void) {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        action()
    }
}
