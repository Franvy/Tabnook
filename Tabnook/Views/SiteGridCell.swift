import SwiftUI
import AppKit

struct SiteGridCell: View {
    static let iconBoxSize: CGFloat = 80
    static let horizontalInset: CGFloat = 8
    static let layoutWidth: CGFloat = iconBoxSize + (horizontalInset * 2)

    let bookmark: FavoriteBookmark
    @Binding var editingBookmarkID: FavoriteBookmark.ID?
    @Environment(\.displayScale) private var displayScale
    @Environment(SiteStore.self) private var store
    @State private var image: CGImage?
    @State private var isLoadingImage = false
    @State private var hovering = false
    @State private var isTargeted = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    private var site: Site { store.site(for: bookmark) }
    private var iconBodyInset: CGFloat {
        site.usesGlassSmallInset ? IconBoxGeometry.glassSmallInset(for: Self.iconBoxSize) : 0
    }
    private var thumbnailPixelSize: Int {
        IconImageProcessor.displayMaxPixelSize(for: Self.iconBoxSize, scale: displayScale)
    }

    var body: some View {
        cellContainer
            .background(hoverBackground)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                store.acceptDrop(url: url, for: site)
                store.setStyle(.glassSmall, for: site)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                return true
            } isTargeted: { targeting in
                isTargeted = targeting
            }
            .help(bookmark.host)
            .modifier(CellAccessibility(bookmark: bookmark,
                                        openInSafari: openInSafari,
                                        revealInFinder: revealInFinder,
                                        resetIcon: { store.resetIcon(for: bookmark) },
                                        beginRename: beginRename))
            .contextMenu { contextMenuContent }
            .task(id: loadKey) {
                await loadImage()
            }
    }

    @ViewBuilder
    private var cellContainer: some View {
        if isRenaming {
            renamingCell
        } else {
            cellButton
        }
    }

    private var cellButton: some View {
        Button {
            editingBookmarkID = bookmark.id
        } label: {
            cellLabel
        }
        .buttonStyle(.plain)
    }

    private var cellLabel: some View {
        VStack(spacing: 8) {
            iconView

            Text(bookmark.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.iconBoxSize)
        .padding(.vertical, 10)
        .padding(.horizontal, Self.horizontalInset)
        .contentShape(.rect(cornerRadius: 12))
    }

    private var renamingCell: some View {
        VStack(spacing: 8) {
            iconView

            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .focused($renameFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused && isRenaming {
                        commitRename()
                    }
                }
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.iconBoxSize)
        .padding(.vertical, 10)
        .padding(.horizontal, Self.horizontalInset)
        .contentShape(.rect(cornerRadius: 12))
        .background(ClickOutsideResigner(isActive: isRenaming))
    }

    @ViewBuilder
    private var iconView: some View {
        StandardIconBox(
            size: Self.iconBoxSize,
            backgroundColor: site.usesGlassBackground
                ? Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.5)
                : .clear
        ) {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .interpolation(.high)
                    .resizable()
                    .scaledToFill()
                    .padding(iconBodyInset)
            } else if isLoadingImage {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { ProgressView().controlSize(.small) }
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "globe")
                            .font(.largeTitle)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(
                    cornerRadius: IconBoxGeometry.cornerRadius(for: Self.iconBoxSize),
                    style: .continuous
                )
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button { editingBookmarkID = bookmark.id } label: {
            Label("Edit Icon", systemImage: "pencil")
        }
        Button(action: beginRename) {
            Label("Rename…", systemImage: "character.cursor.ibeam")
        }
        Divider()
        Button(action: openInSafari) {
            Label("Open in Safari", systemImage: "safari")
        }
        Button(action: revealInFinder) {
            Label("Show Icon File in Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            store.resetIcon(for: bookmark)
        } label: {
            Label("Reset This Site's Icon", systemImage: "arrow.counterclockwise")
        }
    }

    private func beginRename() {
        renameDraft = bookmark.title
        isRenaming = true
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        let draft = renameDraft
        isRenaming = false
        renameFieldFocused = false
        store.renameFavorite(bookmark, to: draft)
    }

    private func cancelRename() {
        isRenaming = false
        renameFieldFocused = false
    }

    private func openInSafari() {
        guard let url = URL(string: bookmark.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([site.iconURL])
    }

    private func loadImage() async {
        let url = site.iconURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            image = nil
            isLoadingImage = false
            return
        }

        isLoadingImage = true
        let pixelSize = thumbnailPixelSize

        let thumbnail = await Task.detached(priority: .userInitiated) { [pixelSize] in
            IconImageProcessor.makeThumbnail(
                at: url,
                maxPixelSize: pixelSize
            )
        }.value

        guard !Task.isCancelled else { return }
        image = thumbnail
        isLoadingImage = false
    }

    @ViewBuilder
    private var hoverBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quinary)
            .opacity(hovering ? 1 : 0)
    }

    private var loadKey: String {
        "\(site.iconURL.path)#\(store.iconVersion.uuidString)"
    }
}

private struct CellAccessibility: ViewModifier {
    let bookmark: FavoriteBookmark
    let openInSafari: () -> Void
    let revealInFinder: () -> Void
    let resetIcon: () -> Void
    let beginRename: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(Text("\(bookmark.title), host \(bookmark.host)"))
            .accessibilityHint(Text("Double click to edit this site's icon"))
            .accessibilityAction(named: Text("Rename"), beginRename)
            .accessibilityAction(named: Text("Open in Safari"), openInSafari)
            .accessibilityAction(named: Text("Show Icon File in Finder"), revealInFinder)
            .accessibilityAction(named: Text("Reset This Site's Icon"), resetIcon)
    }
}
