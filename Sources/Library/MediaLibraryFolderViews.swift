import SwiftUI

struct MediaLibrarySourceFolderRow: View {
    let root: MediaSourceRoot

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "folder.fill")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 46, height: 44)
                .background(AppTheme.background, in: RoundedRectangle(cornerRadius: AppTheme.Corners.folderIcon))
            VStack(alignment: .leading, spacing: 4) {
                Text(root.displayName).font(AppTheme.Typography.mediaTitle)
                Text("\(root.volumeName) · \(root.relativePath)")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("library.sourceOnline")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { AppTheme.separator.frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct MediaLibraryFolderBreadcrumbs: View {
    let root: MediaSourceRoot?
    let directory: MediaLibraryDirectory
    @Binding var path: [MediaLibraryDirectory]

    var body: some View {
        let ancestors = directory.ancestors(relativeTo: root)
        let parentDirectories = Array(ancestors.dropLast())

        return HStack(spacing: 8) {
            Button {
                path = []
            } label: {
                Label("library.nav.folders", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if let root {
                if directory.relativePath != root.relativePath {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    let rootDirectory = MediaLibraryDirectory(sourceRootID: root.id,
                        relativePath: root.relativePath, displayName: root.displayName)
                    Button(root.displayName) {
                        if let prefix = rootDirectory.navigationPathPrefix(in: path) {
                            path = prefix
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            ForEach(parentDirectories) { ancestor in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(ancestor.displayName) {
                    if let prefix = ancestor.navigationPathPrefix(in: path) {
                        path = prefix
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("library.folderBreadcrumb"))
    }
}

struct MediaLibraryFolderTile: View {
    let directory: MediaLibraryDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 82)
                .background(AppTheme.background, in: RoundedRectangle(cornerRadius: AppTheme.Corners.folderIcon))
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
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 34, height: 34)
                .background(AppTheme.background, in: RoundedRectangle(cornerRadius: AppTheme.Corners.folderIcon))
            Text(directory.displayName).font(AppTheme.Typography.mediaTitle)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.06)).frame(height: 1) }
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
                            .font(.callout)
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
