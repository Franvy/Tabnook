import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SiteDetailView: View {
    private static let iconBoxSize: CGFloat = 100

    @Environment(\.displayScale) private var displayScale
    @Environment(SiteStore.self) private var store
    let bookmark: FavoriteBookmark
    let onDismiss: () -> Void

    @State private var iconRefreshID = UUID()
    @State private var previewImage: CGImage?
    @State private var isLoadingPreview = false
    @State private var isTargeted = false
    @State private var pasteFlash = false
    @State private var showingFilePicker = false
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
        VStack(spacing: 0) {
            headerSection
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    styleSection
                    replaceSection
                    advancedSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { SheetWindowConfigurator() }
        .onPasteCommand(of: [UTType.png, UTType.tiff, UTType.jpeg, UTType.fileURL]) { _ in
            pasteFromPasteboard()
        }
        .task(id: previewLoadKey) {
            await loadPreview()
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.png, .jpeg, .tiff, .image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else { return }
            store.acceptDrop(url: url, for: site)
            iconRefreshID = UUID()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 18) {
            iconPreview
                .accessibilityLabel("\(displayName) current icon")

            VStack(alignment: .leading, spacing: 4) {
                nameField
                Text(site.host)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayName: String {
        bookmark.title
    }

    @ViewBuilder
    private var nameField: some View {
        if isRenaming {
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.title2)
                .fontWeight(.semibold)
                .focused($renameFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused && isRenaming {
                        commitRename()
                    }
                }
                .background(ClickOutsideResigner(isActive: isRenaming))
        } else {
            Text(displayName)
                .font(.title2)
                .fontWeight(.semibold)
                .contentShape(.rect)
                .onTapGesture(count: 2) { beginRename() }
                .help("Double-click to rename")
                .accessibilityAction(named: Text("Rename"), beginRename)
        }
    }

    private func beginRename() {
        renameDraft = displayName
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

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Icon Style")

            Picker("Icon Style", selection: styleBinding(for: site)) {
                ForEach(IconStyle.allCases) { style in
                    Text(style.localizedLabel).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if site.needsStyleHint {
                Text(unknownStyleHint(for: site))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var replaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Replace Icon")
            dropZone
            replaceButtonsRow
        }
    }

    private var advancedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                advancedRow(label: "DB Code", value: site.rawStyleValueText)
                advancedRow(label: "Interpreted As", value: site.styleMeaningText)
                advancedRow(label: "Checksum", value: site.md5, monospaced: true)
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced Info")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Shared pieces

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private func advancedRow(label: LocalizedStringKey, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var iconPreview: some View {
        StandardIconBox(
            size: Self.iconBoxSize,
            backgroundColor: site.usesGlassBackground
                ? Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.5)
                : .clear
        ) {
            if let previewImage {
                Image(decorative: previewImage, scale: 1, orientation: .up)
                    .interpolation(.high)
                    .resizable()
                    .scaledToFill()
                    .padding(iconBodyInset)
            } else if isLoadingPreview {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { ProgressView().controlSize(.small) }
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "questionmark.square.dashed")
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(fillColor)
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    Text("Drop a PNG, JPEG, or TIFF here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("or click to choose a file")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : .secondary.opacity(0.35),
                        style: StrokeStyle(
                            lineWidth: isTargeted ? 2 : 1,
                            dash: isTargeted ? [] : [6]
                        )
                    )
            }
            .contentShape(.rect(cornerRadius: 14))
            .onTapGesture { showingFilePicker = true }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                store.acceptDrop(url: url, for: site)
                iconRefreshID = UUID()
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                return true
            } isTargeted: { targeting in
                isTargeted = targeting
            }
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Icon drop zone")
            .accessibilityHint("Drop an image to replace the current icon, or click to choose a file")
            .accessibilityAction(named: "Paste from Clipboard") { pasteFromPasteboard() }
            .accessibilityAction(named: "Choose File") { showingFilePicker = true }
    }

    private var replaceButtonsRow: some View {
        HStack(spacing: 10) {
            Button {
                pasteFromPasteboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .help("Paste Image (⌘V)")

            Button {
                showingFilePicker = true
            } label: {
                Label("Choose File…", systemImage: "folder")
            }

            Spacer()

            Button(role: .destructive) {
                store.resetIcon(for: bookmark)
                iconRefreshID = UUID()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Remove this site's custom icon and revert to Safari's default")
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Logic

    private var previewLoadKey: String {
        "\(site.iconURL.path)#\(store.iconVersion.uuidString)#\(iconRefreshID.uuidString)"
    }

    private func loadPreview() async {
        let url = site.iconURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            previewImage = nil
            isLoadingPreview = false
            return
        }

        isLoadingPreview = true
        let pixelSize = thumbnailPixelSize

        let thumbnail = await Task.detached(priority: .userInitiated) { [pixelSize] in
            IconImageProcessor.makeThumbnail(
                at: url,
                maxPixelSize: pixelSize
            )
        }.value

        guard !Task.isCancelled else { return }
        previewImage = thumbnail
        isLoadingPreview = false
    }

    private func styleBinding(for site: Site) -> Binding<IconStyle> {
        Binding(
            get: { site.style },
            set: { store.setStyle($0, for: site) }
        )
    }

    private func unknownStyleHint(for site: Site) -> String {
        if site.rawStyleValue == nil {
            return String(
                localized: "This favorite currently has no matching cache_settings row. The segmented control shows a fallback value; picking any style writes the corresponding code back to the database."
            )
        }

        return String(
            localized: "This code has no mapping yet. The segmented control shows an editable fallback value; picking any style changes the database value to 0, 1, or 3."
        )
    }

    private var fillColor: Color {
        if isTargeted { return Color.accentColor.opacity(0.15) }
        if pasteFlash { return Color.accentColor.opacity(0.2) }
        return .clear
    }

    private func pasteFromPasteboard() {
        let pb = NSPasteboard.general

        if let data = pb.data(forType: .png) {
            store.acceptDrop(data: data, for: site)
            finishPaste()
            return
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first {
            store.acceptDrop(url: url, for: site)
            finishPaste()
            return
        }

        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            store.acceptDrop(data: png, for: site)
            finishPaste()
            return
        }

        if let anyImageData = pb.data(forType: NSPasteboard.PasteboardType("public.image")),
           let image = NSImage(data: anyImageData),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            store.acceptDrop(data: png, for: site)
            finishPaste()
            return
        }

        NSSound.beep()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    private func finishPaste() {
        iconRefreshID = UUID()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(.easeOut(duration: 0.15)) { pasteFlash = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeOut(duration: 0.25)) { pasteFlash = false }
        }
    }
}

private struct SheetWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(for: nsView)
    }

    private func configure(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}
