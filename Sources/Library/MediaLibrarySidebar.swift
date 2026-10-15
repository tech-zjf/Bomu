import SwiftUI

struct MediaLibrarySidebar: View {
    let selection: LibraryDestination?
    let onlineRoots: [MediaSourceRoot]
    let offlineRoots: [MediaSourceRoot]
    let isStorageAvailable: Bool
    let onSelect: (LibraryDestination) -> Void
    let onOpen: (MediaSourceRoot) -> Void
    let onChooseFolder: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        sectionHeading("library.section.yourMedia")
                        ForEach(LibraryDestination.allCases) { destination in
                            destinationButton(destination)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        sectionHeading("library.section.locations")
                        ForEach(onlineRoots) { root in
                            Button { onOpen(root) } label: {
                                Label(root.displayName, systemImage: "folder")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.textSecondary)
                            .help(root.relativePath)
                        }
                        ForEach(offlineRoots) { root in
                            Label(root.displayName, systemImage: "externaldrive.badge.xmark")
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .foregroundStyle(AppTheme.textSecondary.opacity(0.65))
                                .help(String(localized: "library.sourceOffline"))
                        }
                        Button(action: onChooseFolder) {
                            Label("library.addFolder", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.textSecondary)
                        .disabled(!isStorageAvailable)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.top, 19)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            VStack(alignment: .leading, spacing: 8) {
                Label("library.localOnly", systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                Button(action: onShowSettings) {
                    Label("library.nav.settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .frame(width: AppTheme.Layout.sidebarWidth)
        .background(AppTheme.background.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            AppTheme.separator.frame(width: 1).ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
    }

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 3)
            .padding(.bottom, 3)
    }

    private func destinationButton(_ destination: LibraryDestination) -> some View {
        let isSelected = selection == destination

        return Button { onSelect(destination) } label: {
            Label(destination.title, systemImage: destination.symbol)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(isSelected ? AppTheme.surface : .clear,
                            in: RoundedRectangle(cornerRadius: AppTheme.Corners.selection))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
