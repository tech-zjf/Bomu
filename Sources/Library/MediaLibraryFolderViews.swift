import SwiftUI

struct MediaLibrarySourceFolderRow: View {
    let root: MediaSourceRoot

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "folder.fill")
                .font(AppTheme.Typography.Symbol.folderRow)
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: AppTheme.Layout.folderListIconSize, height: AppTheme.Layout.folderListIconSize)
                .background(AppTheme.mutedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Corners.folderIcon))
            VStack(alignment: .leading, spacing: 4) {
                Text(root.displayName).font(AppTheme.Typography.mediaTitle).lineLimit(1)
                Text("\(root.volumeName) · \(root.relativePath)")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(root.isOnline ? "library.sourceOnline" : "library.sourceOffline")
                .font(AppTheme.Typography.compactBadge)
                .foregroundStyle(AppTheme.textSecondary)
            Image(systemName: "chevron.right")
                .font(AppTheme.Typography.Symbol.folderDisclosure)
                .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
        }
        .padding(.vertical, AppTheme.Layout.folderRowVerticalInset)
        .overlay(alignment: .bottom) { AppTheme.separator.frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct MediaLibraryFolderBreadcrumbs: View {
    let directory: MediaLibraryDirectory
    @Binding var path: [MediaLibraryDirectory]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                foldersButton
                ForEach(parentDirectories) { ancestor in
                    separator
                    Button(ancestor.displayName) { navigate(to: ancestor) }
                        .buttonStyle(BreadcrumbButtonStyle())
                        .help(ancestor.displayName)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 8) {
                foldersButton
                if !parentDirectories.isEmpty {
                    separator
                    Menu {
                        ForEach(parentDirectories) { ancestor in
                            Button(ancestor.displayName) { navigate(to: ancestor) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(AppTheme.Typography.Symbol.mediaActions)
                            .frame(width: AppTheme.Layout.compactControlSize,
                                   height: AppTheme.Layout.compactControlSize)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel(Text("library.folderBreadcrumb"))
                    .help(Text("library.folderBreadcrumb"))
                }
            }
        }
        .foregroundStyle(AppTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("library.folderBreadcrumb"))
    }

    // Render only actual destinations in the current stack; both layouts use the same path.
    private var parentDirectories: [MediaLibraryDirectory] {
        guard let currentPath = directory.navigationPathPrefix(in: path) else { return [] }
        return Array(currentPath.dropLast())
    }

    private var foldersButton: some View {
        Button { path = [] } label: {
            Label("library.nav.folders", systemImage: "chevron.left")
        }
        .buttonStyle(BreadcrumbButtonStyle())
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(AppTheme.Typography.Symbol.folderBreadcrumb)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func navigate(to ancestor: MediaLibraryDirectory) {
        if let prefix = ancestor.navigationPathPrefix(in: path) {
            path = prefix
        }
    }
}

struct MediaLibraryFolderTile: View {
    let directory: MediaLibraryDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(AppTheme.Typography.Symbol.folderTile)
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 82)
                .background(AppTheme.mutedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Corners.folderIcon))
            Text(directory.displayName)
                .font(AppTheme.Typography.mediaTitle)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct MediaLibraryFolderRow: View {
    let directory: MediaLibraryDirectory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(AppTheme.Typography.Symbol.folderRow)
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: AppTheme.Layout.folderListIconSize, height: AppTheme.Layout.folderListIconSize)
                .background(AppTheme.mutedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Corners.folderIcon))
            Text(directory.displayName).font(AppTheme.Typography.mediaTitle).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(AppTheme.Typography.Symbol.folderDisclosure)
                .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
        }
        .padding(.vertical, AppTheme.Layout.folderRowVerticalInset)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { AppTheme.separator.frame(height: 1) }
    }
}

struct MediaLibraryOfflineSources: View {
    let roots: [MediaSourceRoot]

    var body: some View {
        if !roots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("library.offlineTitle")
                    .font(AppTheme.Typography.sectionTitle)
                ForEach(roots) { root in
                    HStack(spacing: 10) {
                        Label("\(root.displayName) · \(root.volumeName)", systemImage: "externaldrive.badge.xmark")
                            .font(AppTheme.Typography.callout)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("library.sourceOffline")
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        AppTheme.separator.frame(height: 1)
                    }
                }
                Text("library.offlineMessage")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BreadcrumbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.Typography.controlBody)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .frame(minHeight: AppTheme.Layout.compactControlSize)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
