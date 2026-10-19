import SwiftUI

struct MediaLibrarySidebar: View {
    let selection: LibraryDestination
    let onlineRoots: [MediaSourceRoot]
    let offlineRoots: [MediaSourceRoot]
    let isStorageAvailable: Bool
    let onSelect: (LibraryDestination) -> Void
    let onOpen: (MediaSourceRoot) -> Void
    let onChooseFolder: () -> Void
    let onShowSettings: () -> Void
    let isSettingsSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sidebarSectionSpacing) {
                    VStack(alignment: .leading, spacing: 5) {
                        sectionHeading("library.section.yourMedia")
                        ForEach(LibraryDestination.allCases) { destination in
                            destinationButton(destination)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        sectionHeading("library.section.locations")
                        ForEach(onlineRoots) { root in
                            sourceButton(root)
                        }
                        ForEach(offlineRoots) { root in
                            sourceButton(root)
                        }
                        Button(action: onChooseFolder) {
                            Label("library.addFolder", systemImage: "plus")
                        }
                        .buttonStyle(SidebarRowButtonStyle())
                        .disabled(!isStorageAvailable)
                    }
                }
                .font(AppTheme.Typography.sidebarLabel)
                .padding(.horizontal, AppTheme.Layout.sidebarHorizontalInset)
                .padding(.top, AppTheme.Layout.sidebarTopInset)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            VStack(alignment: .leading, spacing: AppTheme.Layout.sidebarSectionSpacing) {
                Label("library.localOnly", systemImage: "lock.shield")
                    .font(AppTheme.Typography.sidebarLocalTag)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, AppTheme.Layout.sidebarLocalTagTopInset)
                Button(action: onShowSettings) {
                    Label("library.nav.settings", systemImage: "gearshape")
                }
                .buttonStyle(SidebarRowButtonStyle(isSelected: isSettingsSelected))
            }
            .font(AppTheme.Typography.sidebarLabel)
            .padding(.horizontal, AppTheme.Layout.sidebarHorizontalInset)
            .padding(.bottom, AppTheme.Layout.sidebarBottomInset)
        }
        .frame(width: AppTheme.Layout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(AppTheme.mutedSurface)
        .labelStyle(SidebarLabelStyle())
        .accessibilityElement(children: .contain)
    }

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(AppTheme.Typography.sidebarSection)
            .foregroundStyle(AppTheme.textSecondary)
            .tracking(0.7)
            .padding(.horizontal, AppTheme.Layout.sidebarRowHorizontalInset)
            .padding(.top, AppTheme.Layout.sidebarHeadingTopInset)
            .padding(.bottom, AppTheme.Layout.sidebarHeadingBottomInset)
    }

    private func sourceButton(_ root: MediaSourceRoot) -> some View {
        Button { onOpen(root) } label: {
            Label(root.displayName, systemImage: root.isOnline ? "folder" : "externaldrive.badge.xmark")
        }
        .buttonStyle(SidebarRowButtonStyle())
        .help(root.isOnline ? root.relativePath : String(localized: "library.sourceOffline"))
    }

    private func destinationButton(_ destination: LibraryDestination) -> some View {
        let isSelected = selection == destination

        return Button { onSelect(destination) } label: {
            Label(destination.title, systemImage: destination.symbol)
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AppTheme.Layout.sidebarIconGap) {
            configuration.icon
                .font(AppTheme.Typography.Symbol.sidebar)
                .frame(width: AppTheme.Layout.sidebarIconWidth)
            configuration.title
        }
    }
}

/// Every sidebar action uses the same full-row bounds, including transparent space.
private struct SidebarRowButtonStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isSelected ? AppTheme.Typography.sidebarSelected : AppTheme.Typography.sidebarLabel)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Layout.sidebarRowHorizontalInset)
            .frame(height: AppTheme.Layout.sidebarRowHeight)
            .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
            .background(background(isPressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: AppTheme.Corners.selection))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovered = $0 }
    }

    private func background(isPressed: Bool) -> Color {
        if isSelected { return AppTheme.surface }
        if isEnabled && isPressed { return AppTheme.surface.opacity(0.9) }
        if isEnabled && isHovered { return AppTheme.surface.opacity(0.55) }
        return .clear
    }
}
