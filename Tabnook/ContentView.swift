import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(SiteStore.self) private var store
    @State private var selectedBookmarkID: FavoriteBookmark.ID?
    @State private var isApplying = false
    @AppStorage("backgroundOpacity") private var backgroundOpacity: Double = 0.5

    var body: some View {
        content
            .containerBackground(for: .window) {
                ZStack {
                    Color.clear
                        .glassEffect(.clear, in: Rectangle())
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(backgroundOpacity)
                }
                .ignoresSafeArea()
            }
            .background { SafariWindowConfigurator(opaque: backgroundOpacity >= 1.0) }
            .overlay {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RestartSafariButton(isApplying: $isApplying)
                            .padding(.top, 16)
                            .padding(.trailing, 16)
                    }
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .overlay(alignment: .top) {
                if let info = store.transientInfo {
                    ToastView(message: info.message)
                        .padding(.top, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: info.id) {
                            try? await Task.sleep(for: .seconds(3))
                            if store.transientInfo?.id == info.id {
                                store.transientInfo = nil
                            }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: store.transientInfo?.id)
            .navigationTitle("Tabnook")
            .frame(minWidth: 720, minHeight: 520)
            .task(id: diagnosticScopeKey) {
                store.updateDiagnosticScope(bookmarks: store.favoriteBookmarks)
            }
            .sheet(isPresented: detailPresentedBinding) {
                if let bookmark = selectedBookmark {
                    SiteDetailView(bookmark: bookmark) {
                        selectedBookmarkID = nil
                    }
                    .frame(minWidth: 480, minHeight: 500)
                    .environment(store)
                } else {
                    ContentUnavailableView("Site Not Found", systemImage: "questionmark.app")
                        .frame(minWidth: 360, minHeight: 240)
                }
            }
            .sheet(isPresented: diagnosticReportBinding) {
                if let report = store.diagnosticReport {
                    DiagnosticReportView(report: report) {
                        store.diagnosticReport = nil
                    }
                }
            }
            .alert(
                "Action Didn't Complete",
                isPresented: transientErrorBinding,
                actions: {
                    Button("OK") { store.transientError = nil }
                },
                message: {
                    Text(store.transientError?.message ?? "")
                }
            )
    }

    private var transientErrorBinding: Binding<Bool> {
        Binding(
            get: { store.transientError != nil },
            set: { newValue in
                if !newValue { store.transientError = nil }
            }
        )
    }

    private var detailPresentedBinding: Binding<Bool> {
        Binding(
            get: { selectedBookmarkID != nil },
            set: { newValue in
                if !newValue { selectedBookmarkID = nil }
            }
        )
    }

    private var diagnosticReportBinding: Binding<Bool> {
        Binding(
            get: { store.diagnosticReport != nil },
            set: { newValue in
                if !newValue { store.diagnosticReport = nil }
            }
        )
    }

    private var selectedBookmark: FavoriteBookmark? {
        guard let selectedBookmarkID else { return nil }
        return store.favoriteBookmarks.first(where: { $0.id == selectedBookmarkID })
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .needsPermission, .idle:
            grantView
        case .loading:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Reading Safari data…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Unable to read Safari database", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
            } description: {
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } actions: {
                Button("Re-authorize") { store.requestAccess() }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded:
            if let err = store.bookmarksError {
                bookmarksErrorView(message: err)
            } else {
                SiteGridView(bookmarks: store.favoriteBookmarks, editingBookmarkID: $selectedBookmarkID)
            }
        }
    }

    private var diagnosticScopeKey: String {
        store.favoriteBookmarks.map(\.id).joined(separator: "|")
    }

    private var grantView: some View {
        ContentUnavailableView {
            Label("Access Required", systemImage: "lock.shield.fill")
                .symbolRenderingMode(.hierarchical)
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tabnook needs to read the following to manage your favorite icons:")
                Label("Safari favorites list", systemImage: "bookmark")
                Label("Touch Icons cache", systemImage: "photo.on.rectangle")
                Label("Write and lock icon files", systemImage: "lock")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 360, alignment: .leading)
        } actions: {
            Button("Grant Access…") { store.requestAccess() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func bookmarksErrorView(message: String) -> some View {
        ContentUnavailableView {
            Label("Unable to read favorites", systemImage: "bookmark.slash.fill")
                .symbolRenderingMode(.hierarchical)
        } description: {
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        } actions: {
            Button("Re-authorize ~/Library/Safari/") { store.requestAccess() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
    }
}

private struct RestartSafariButton: View {
    @Binding var isApplying: Bool

    var body: some View {
        Button(action: restart) {
            ZStack {
                if isApplying {
                    RestartPulseRing()
                        .transition(.opacity)
                }

                Circle()
                    .fill(.regularMaterial)

                Circle()
                    .strokeBorder(
                        isApplying ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                        lineWidth: isApplying ? 1.5 : 1
                    )

                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    RocketIconShape()
                        .stroke(
                            .primary,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 16, height: 16)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.5).combined(with: .opacity),
                                removal: .offset(x: 18, y: -18).combined(with: .opacity)
                            )
                        )
                }
            }
            .frame(width: 30, height: 30)
            .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
        }
        .buttonStyle(.plain)
        .help("Restart Safari to apply icon changes (⌘R)")
        .keyboardShortcut("r", modifiers: .command)
        .disabled(isApplying)
        .accessibilityLabel(isApplying ? "Restarting Safari" : "Restart Safari to apply changes")
        .animation(.spring(duration: 0.35, bounce: 0.25), value: isApplying)
    }

    private func restart() {
        guard !isApplying else { return }
        isApplying = true
        Task {
            await SafariProcess.restart()
            try? await Task.sleep(for: .milliseconds(600))
            isApplying = false
        }
    }
}

private struct RestartPulseRing: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cycle = 1.6
            let p1 = t.truncatingRemainder(dividingBy: cycle) / cycle
            let p2 = (t + cycle / 2).truncatingRemainder(dividingBy: cycle) / cycle

            ZStack {
                pulseCircle(progress: p1)
                pulseCircle(progress: p2)
            }
        }
        .frame(width: 30, height: 30)
        .allowsHitTesting(false)
    }

    private func pulseCircle(progress: Double) -> some View {
        Circle()
            .stroke(Color.accentColor.opacity(0.45 * (1 - progress)), lineWidth: 1.5)
            .scaleEffect(1 + progress * 0.55)
    }
}

private struct RocketIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let offsetX = rect.minX + (rect.width - 24 * scale) / 2
        let offsetY = rect.minY + (rect.height - 24 * scale) / 2

        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }

        var path = Path()

        path.move(to: p(12, 15))
        path.addLine(to: p(12, 20))
        path.addCurve(
            to: p(16, 18),
            control1: p(12, 20),
            control2: p(15.03, 19.45)
        )
        path.addCurve(
            to: p(16, 13),
            control1: p(17.08, 16.38),
            control2: p(16, 13)
        )

        path.move(to: p(4.5, 16.5))
        path.addCurve(
            to: p(2.5, 21.5),
            control1: p(3, 17.76),
            control2: p(2.5, 21.5)
        )
        path.addCurve(
            to: p(7.5, 19.5),
            control1: p(2.5, 21.5),
            control2: p(6.24, 21)
        )
        path.addCurve(
            to: p(7.41, 16.59),
            control1: p(8.21, 18.66),
            control2: p(8.2, 17.37)
        )
        path.addCurve(
            to: p(5.97223, 15.988),
            control1: p(7.02131, 16.219),
            control2: p(6.50929, 16.0046)
        )
        path.addCurve(
            to: p(4.5, 16.5),
            control1: p(5.43516, 15.9714),
            control2: p(4.91088, 16.1537)
        )
        path.closeSubpath()

        path.move(to: p(9, 12))
        path.addCurve(
            to: p(11, 8.05),
            control1: p(9.53214, 10.6194),
            control2: p(10.2022, 9.29607)
        )
        path.addCurve(
            to: p(15.713, 3.5941),
            control1: p(12.1652, 6.18699),
            control2: p(13.7876, 4.65305)
        )
        path.addCurve(
            to: p(22, 2),
            control1: p(17.6384, 2.53514),
            control2: p(19.8027, 1.98637)
        )
        path.addCurve(
            to: p(16, 13),
            control1: p(22, 4.72),
            control2: p(21.22, 9.5)
        )
        path.addCurve(
            to: p(12, 15),
            control1: p(14.7367, 13.7984),
            control2: p(13.3967, 14.4684)
        )
        path.addLine(to: p(9, 12))

        path.move(to: p(9, 12))
        path.addLine(to: p(4, 12))
        path.addCurve(
            to: p(6, 7.99999),
            control1: p(4, 12),
            control2: p(4.55, 8.96999)
        )
        path.addCurve(
            to: p(11, 8.04999),
            control1: p(7.62, 6.91999),
            control2: p(11, 8.04999)
        )

        return path
    }
}

private struct DiagnosticReportView: View {
    let report: DiagnosticReport
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(report.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(report.message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 320)
    }
}

private struct SafariWindowConfigurator: NSViewRepresentable {
    let opaque: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        let opaque = self.opaque
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            if opaque {
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
                window.contentView?.layer?.backgroundColor = nil
            } else {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }
}

