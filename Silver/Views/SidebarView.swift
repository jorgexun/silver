import SwiftUI

struct SidebarView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        let folders = library.folders

        List(selection: Binding(
            get: { library.folderURL },
            set: { url in if let url { library.openFolder(url) } }
        )) {
            Section("Folders") {
                ForEach(folders.rows) { row in
                    FolderRow(row: row)
                        .tag(row.node.url)
                        .contextMenu { contextMenu(for: row) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if folders.roots.isEmpty {
                VStack(spacing: 8) {
                    Text("No Folders")
                        .foregroundStyle(.secondary)
                    Button("Add Folder…") { library.presentAddFolderPanel() }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Add Folder", systemImage: "plus") { library.presentAddFolderPanel() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Add Folder (⌘O)")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func contextMenu(for row: SourceFolders.Row) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([row.node.url])
        }
        Button("Reload") {
            library.folders.refresh(row.node)
            if library.folderURL == row.node.url { library.reloadFolder() }
        }
        if row.isRoot {
            Divider()
            Button("Remove from Sidebar") { library.removeFolder(row.node) }
        }
    }
}

private struct FolderRow: View {
    @Environment(LibraryModel.self) private var library
    let row: SourceFolders.Row

    var body: some View {
        let node = row.node
        HStack(spacing: 2) {
            Group {
                if node.hasSubfolders {
                    Button {
                        library.folders.setExpanded(node, !node.isExpanded)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            Label(node.name, systemImage: row.isRoot ? "folder.fill" : "folder")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .help(node.url.path(percentEncoded: false))
    }
}
