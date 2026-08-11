import Foundation
import AppKit
import Observation
import os

enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case needsPermission
    case failed(String)
}

struct TransientError: Identifiable {
    let id = UUID()
    let message: String
}

struct TransientInfo: Identifiable {
    let id = UUID()
    let message: String
}

struct DiagnosticReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@Observable
@MainActor
final class SiteStore {
    private(set) var sites: [Site] = []
    private(set) var favoriteBookmarks: [FavoriteBookmark] = []
    private(set) var state: LoadState = .idle
    private(set) var bookmarksError: String?
    private(set) var bookmarksDiagnostics: BookmarksResult?
    private(set) var iconVersion: UUID = UUID()
    var transientError: TransientError?
    var transientInfo: TransientInfo?
    var diagnosticReport: DiagnosticReport?
    
    private var siteByHost: [String: Site] = [:]
    
    private static let log = Logger(subsystem: "com.franvy.Tabnook", category: "SiteStore")
    
    private let store: IconStore
    let backup: BackupStore
    private var reconcileTask: Task<Void, Never>?
    private var dbWatcher: DispatchSourceFileSystemObject?
    private var dbWatchedFD: Int32 = -1
    private var bookmarksWatcher: DispatchSourceFileSystemObject?
    private var bookmarksWatchedFD: Int32 = -1
    private var reloadDebounceTask: Task<Void, Never>?
    private var favoritesDebounceTask: Task<Void, Never>?
    private var iconRepairTask: Task<Void, Never>?
    private var diagnosticScopeBookmarks: [FavoriteBookmark] = []
    private var dbWatcherNeedsRestart = false
    private var bookmarksWatcherNeedsRestart = false
    private var imagesWatcher: DispatchSourceFileSystemObject?
    private var imagesWatchedFD: Int32 = -1
    private var imagesWatcherNeedsRestart = false
    private var backupReconcileDebounceTask: Task<Void, Never>?
    private var suppressImagesWatcherUntil: ContinuousClock.Instant?
    private var pendingImagesEvent = false
    private var suppressionDrainTask: Task<Void, Never>?
    private var pendingRenames: [FavoriteBookmark.ID: (bookmark: FavoriteBookmark, title: String)] = [:]
    private var renamePersistTask: Task<Void, Never>?
    
    func site(for bookmark: FavoriteBookmark) -> Site {
        let h = bookmark.host.lowercased()
        if let hit = siteByHost[h] { return hit }
        let alternate: String
        if h.hasPrefix("www.") {
            alternate = String(h.dropFirst(4))
        } else {
            alternate = "www." + h
        }
        if let hit = siteByHost[alternate] { return hit }
        Self.log.warning("no cache_settings row for bookmark host=\(bookmark.host, privacy: .public); falling back to glassSmall")
        return Site(host: bookmark.host, rawStyleValue: nil, paths: store.paths)
    }
    
    private func rebuildSiteIndex() {
        var index: [String: Site] = [:]
        index.reserveCapacity(sites.count)
        for site in sites {
            index[site.host.lowercased()] = site
        }
        siteByHost = index
    }
    
    init(store: IconStore = IconStore(), backup: BackupStore = BackupStore()) {
        self.store = store
        self.backup = backup
    }
    
    func renameFavorite(_ bookmark: FavoriteBookmark, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != bookmark.title else { return }
        do {
            try BookmarksWriter.renameFavorite(bookmark, newTitle: trimmed, paths: store.paths)
            pendingRenames[bookmark.id] = (bookmark, trimmed)
            loadFavorites()
            scheduleRenamePersist()
        } catch {
            reportTransient(error, context: "Rename favorite")
        }
    }
    
    // A running Safari keeps Bookmarks.plist in memory and can flush its copy back
    // to disk later, silently reverting our rename. Debounce so a burst of renames
    // collapses into one restart, then quit Safari, re-apply the titles while it's
    // closed, and relaunch so it reads our version on the way up.
    private func scheduleRenamePersist() {
        renamePersistTask?.cancel()
        renamePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await self?.persistPendingRenames()
        }
    }
    
    private func persistPendingRenames() async {
        guard !pendingRenames.isEmpty else { return }
        let pending = pendingRenames
        let paths = store.paths
        
        let wasRunning = await SafariProcess.quit()
        if wasRunning {
            transientInfo = TransientInfo(message: String(localized: "Restarting Safari to apply the new name"))
            for (_, item) in pending {
                try? BookmarksWriter.renameFavorite(item.bookmark, newTitle: item.title, paths: paths)
            }
        }
        pendingRenames.removeAll()
        if wasRunning {
            await SafariProcess.launch()
        }
        loadFavorites()
    }
    
    func load() {
        if dbWatcherNeedsRestart {
            dbWatcherNeedsRestart = !restartDBWatcher()
        }
        if imagesWatcherNeedsRestart {
            imagesWatcherNeedsRestart = !restartImagesWatcher()
        }
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.paths.db.path) else {
            state = .needsPermission
            return
        }
        guard fm.isReadableFile(atPath: store.paths.db.path) else {
            state = .needsPermission
            return
        }
        
        if state != .loaded {
            state = .loading
        }
        do {
            sites = try store.listSites()
            rebuildSiteIndex()
            Self.log.info("loaded \(self.sites.count, privacy: .public) sites from cache_settings")
            for site in sites.prefix(10) {
                let rawStyleValue = site.rawStyleValue ?? -1
                Self.log.debug("site host=\(site.host, privacy: .public) rawStyle=\(rawStyleValue, privacy: .public) resolvedStyle=\(site.style.rawValue, privacy: .public)")
            }
            state = .loaded
            scheduleReconcile()
        } catch {
            state = .failed(userMessage(from: error))
        }
    }
    
    private func scheduleReconcile() {
        reconcileTask?.cancel()
        // We intentionally do NOT suppress the images watcher here. reconcile's
        // own restore writes are idempotent — restoreIconFile copies the exact
        // backup bytes, so the follow-up watcher event triggers at most one more
        // reconcile that finds every sha already matching and writes nothing.
        // Suppressing here is what used to swallow Safari's reset events that
        // arrived right after launch, leaving icons blank until a manual restart.
        let backup = backup
        let iconStore = store
        reconcileTask = Task { [weak self] in
            let report: ReconcileReport
            do {
                report = try await backup.reconcile(iconStore: iconStore)
            } catch {
                Self.log.error("reconcile failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if report.schemaTooNew {
                    self.transientError = TransientError(
                        message: String(localized: "Backup was written by a newer Tabnook; restore paused to prevent data loss.")
                    )
                    return
                }
                if !report.restoredHosts.isEmpty {
                    self.iconVersion = UUID()
                    self.transientInfo = TransientInfo(
                        message: String(localized: "Restored \(report.restoredHosts.count) custom icons from backup")
                    )
                }
            }
        }
    }
    
    func loadFavorites() {
        if bookmarksWatcherNeedsRestart {
            bookmarksWatcherNeedsRestart = !restartBookmarksWatcher()
        }
        
        do {
            let result = try BookmarksReader.loadFavorites(paths: store.paths)
            favoriteBookmarks = result.bookmarks
            bookmarksDiagnostics = result
            bookmarksError = nil
            scheduleFavoriteIconRepair(for: result.bookmarks)
        } catch {
            favoriteBookmarks = []
            bookmarksDiagnostics = nil
            bookmarksError = userMessage(from: error)
            iconRepairTask?.cancel()
            iconRepairTask = nil
        }
    }
    
    func requestAccess() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Authorize Access to Safari Data")
        panel.message = String(
            localized: "Tabnook needs to read Bookmarks.plist (your favorites) and Touch Icons Cache (icons) inside ~/Library/Safari/. Select the Safari folder below and click Authorize."
        )
        panel.prompt = String(localized: "Authorize")
        panel.directoryURL = store.paths.safari
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        _ = panel.runModal()
        try? store.lockImages(false)
        load()
        loadFavorites()
        startWatching()
    }
    
    func startWatching() {
        stopWatching()
        dbWatcherNeedsRestart = false
        bookmarksWatcherNeedsRestart = false
        imagesWatcherNeedsRestart = false
        _ = startDBWatcher()
        _ = startBookmarksWatcher()
        _ = startImagesWatcher()
    }
    
    func stopWatching() {
        reloadDebounceTask?.cancel()
        reloadDebounceTask = nil
        favoritesDebounceTask?.cancel()
        favoritesDebounceTask = nil
        iconRepairTask?.cancel()
        iconRepairTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        backupReconcileDebounceTask?.cancel()
        backupReconcileDebounceTask = nil
        suppressionDrainTask?.cancel()
        suppressionDrainTask = nil
        pendingImagesEvent = false
        suppressImagesWatcherUntil = nil
        dbWatcher?.cancel()
        dbWatcher = nil
        dbWatchedFD = -1
        bookmarksWatcher?.cancel()
        bookmarksWatcher = nil
        bookmarksWatchedFD = -1
        imagesWatcher?.cancel()
        imagesWatcher = nil
        imagesWatchedFD = -1
        dbWatcherNeedsRestart = false
        bookmarksWatcherNeedsRestart = false
        imagesWatcherNeedsRestart = false
    }
    
    private func scheduleReload() {
        reloadDebounceTask?.cancel()
        reloadDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }
    
    private func scheduleFavoritesReload() {
        favoritesDebounceTask?.cancel()
        favoritesDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.loadFavorites()
        }
    }
    
    private func startDBWatcher() -> Bool {
        let dbPath = store.paths.db.path
        let fd = open(dbPath, O_EVTONLY)
        guard fd >= 0 else {
            return false
        }
        
        dbWatchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            self?.handleDBWatcherEvent(event)
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        dbWatcher = source
        return true
    }
    
    private func startBookmarksWatcher() -> Bool {
        let bookmarksPath = store.paths.safari.appendingPathComponent("Bookmarks.plist").path
        let fd = open(bookmarksPath, O_EVTONLY)
        guard fd >= 0 else {
            return false
        }
        
        bookmarksWatchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            self?.handleBookmarksWatcherEvent(event)
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        bookmarksWatcher = source
        return true
    }
    
    private func restartDBWatcher() -> Bool {
        dbWatcher?.cancel()
        dbWatcher = nil
        dbWatchedFD = -1
        return startDBWatcher()
    }
    
    private func restartBookmarksWatcher() -> Bool {
        bookmarksWatcher?.cancel()
        bookmarksWatcher = nil
        bookmarksWatchedFD = -1
        return startBookmarksWatcher()
    }
    
    private func startImagesWatcher() -> Bool {
        let imagesPath = store.paths.images.path
        let fd = open(imagesPath, O_EVTONLY)
        guard fd >= 0 else {
            return false
        }
        
        imagesWatchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            self?.handleImagesWatcherEvent(event)
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        imagesWatcher = source
        return true
    }
    
    private func restartImagesWatcher() -> Bool {
        imagesWatcher?.cancel()
        imagesWatcher = nil
        imagesWatchedFD = -1
        return startImagesWatcher()
    }
    
    private func handleImagesWatcherEvent(_ event: DispatchSource.FileSystemEvent) {
        if !event.intersection([.rename, .delete]).isEmpty {
            imagesWatcherNeedsRestart = true
        }
        // While a mutation window is open we ignore changes we caused ourselves
        // (drops, resets). But a Safari reset can overlap that window, so record
        // that a real change arrived and drain it once the window closes —
        // otherwise the coalesced event is lost forever and the icon stays blank.
        if let until = suppressImagesWatcherUntil, ContinuousClock().now < until {
            pendingImagesEvent = true
            return
        }
        scheduleBackupReconcile()
    }
    
    // Safari resetting an icon just deletes/replaces the PNG in Images/ without
    // necessarily touching the cache db, so the db watcher never fires. Watch the
    // folder directly and re-run reconcile to restore custom icons from backup.
    private func scheduleBackupReconcile() {
        backupReconcileDebounceTask?.cancel()
        backupReconcileDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.scheduleReconcile()
        }
    }
    
    private func suppressImagesWatcher(for duration: Duration = .seconds(3)) {
        suppressImagesWatcherUntil = ContinuousClock().now.advanced(by: duration)
        // After the window closes, run reconcile once if any external change was
        // observed while suppressed, so a Safari reset overlapping our own write
        // is recovered rather than permanently dropped.
        suppressionDrainTask?.cancel()
        suppressionDrainTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            guard let self, self.pendingImagesEvent else { return }
            self.pendingImagesEvent = false
            self.scheduleBackupReconcile()
        }
    }
    
    private func handleDBWatcherEvent(_ event: DispatchSource.FileSystemEvent) {
        if !event.intersection([.rename, .delete]).isEmpty {
            dbWatcherNeedsRestart = true
        }
        scheduleReload()
    }
    
    private func handleBookmarksWatcherEvent(_ event: DispatchSource.FileSystemEvent) {
        if !event.intersection([.rename, .delete]).isEmpty {
            bookmarksWatcherNeedsRestart = true
        }
        scheduleFavoritesReload()
    }
    
    private func scheduleFavoriteIconRepair(for bookmarks: [FavoriteBookmark]) {
        iconRepairTask?.cancel()
        
        let iconURLs = Array(Set(bookmarks.map(\.iconURL)))
        guard !iconURLs.isEmpty else {
            iconRepairTask = nil
            return
        }
        
        let iconStore = store
        iconRepairTask = Task { [iconStore] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            
            let repairedAny = await Task.detached(priority: .utility) {
                try? iconStore.repairStoredIconsIfNeeded(at: iconURLs)
            }.value ?? false
            
            guard !Task.isCancelled, repairedAny else { return }
            iconVersion = UUID()
        }
    }
    
    func setStyle(_ style: IconStyle, for site: Site) {
        do {
            try store.setStyle(host: site.host, style: style)
            if let idx = sites.firstIndex(where: { $0.host == site.host }) {
                sites[idx].style = style
                siteByHost[site.host.lowercased()] = sites[idx]
            }
        } catch {
            reportTransient(error, context: "Set icon style")
        }
    }
    
    func acceptDrop(url: URL, for site: Site) {
        do {
            let pngData = try store.writeIcon(from: url, for: site)
            suppressImagesWatcher()
            iconVersion = UUID()
            recordBackup(host: site.host, md5: site.md5, pngData: pngData, sourceKind: .file)
        } catch {
            reportTransient(error, context: "Write icon")
        }
    }
    
    func acceptDrop(data: Data, for site: Site) {
        do {
            let pngData = try store.writeIcon(data: data, for: site)
            suppressImagesWatcher()
            iconVersion = UUID()
            recordBackup(host: site.host, md5: site.md5, pngData: pngData, sourceKind: .dropData)
        } catch {
            reportTransient(error, context: "Write icon")
        }
    }
    
    func resetDefaults() {
        do {
            try store.resetDefaults()
            // resetDefaults wipes the whole Touch Icons Cache (Images included), so
            // the folder watcher's descriptor goes stale and there's nothing to
            // reconcile back (forgetAll clears backups too).
            suppressImagesWatcher(for: .seconds(8))
            imagesWatcherNeedsRestart = true
            sites = []
            siteByHost = [:]
            iconVersion = UUID()
            let backup = backup
            Task {
                try? await backup.forgetAll()
            }
        } catch {
            reportTransient(error, context: "Reset default icons")
        }
    }
    
    func resetIcon(for bookmark: FavoriteBookmark) {
        let site = site(for: bookmark)
        do {
            try store.removeStoredIcon(for: site)
            suppressImagesWatcher()
            iconVersion = UUID()
            let backup = backup
            let host = site.host
            Task {
                try? await backup.forget(host: host)
            }
        } catch {
            reportTransient(error, context: "Reset icon")
        }
    }
    
    private func recordBackup(host: String, md5: String, pngData: Data, sourceKind: BackupSourceKind) {
        let backup = backup
        Task { [weak self] in
            do {
                _ = try await backup.recordBackup(host: host, pngData: pngData, md5: md5, sourceKind: sourceKind)
            } catch {
                await MainActor.run {
                    self?.transientError = TransientError(
                        message: String(localized: "Backup write failed: \(error.localizedDescription). Your icon is applied but unprotected.")
                    )
                }
            }
        }
    }
    
    func revealBackupFolder() {
        let backup = backup
        Task {
            await backup.revealInFinder()
        }
    }
    
    func setBackupRoot(_ url: URL, migrateExisting: Bool) {
        let backup = backup
        Task { [weak self] in
            do {
                try await backup.setRootURL(url, migrateExisting: migrateExisting)
                await MainActor.run {
                    self?.transientInfo = TransientInfo(message: String(localized: "Backup folder changed"))
                    self?.scheduleReconcile()
                }
            } catch {
                await MainActor.run {
                    self?.transientError = TransientError(
                        message: "Set backup folder failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
    
    func resetBackupRootToDefault() {
        let backup = backup
        Task { [weak self] in
            do {
                try await backup.resetToDefaultRoot()
                await MainActor.run {
                    self?.transientInfo = TransientInfo(message: String(localized: "Reverted to default backup folder"))
                    self?.scheduleReconcile()
                }
            } catch {
                await MainActor.run {
                    self?.transientError = TransientError(
                        message: String(localized: "Reset backup folder failed: \(error.localizedDescription)")
                    )
                }
            }
        }
    }
    
    func currentBackupRootURL() async -> URL {
        await backup.currentRootURL
    }
    
    func setImagesLocked(_ locked: Bool) {
        do {
            try store.lockImages(locked)
        } catch {
            reportTransient(error, context: locked ? "Lock icons folder" : "Unlock icons folder")
        }
    }
    
    func updateDiagnosticScope(bookmarks: [FavoriteBookmark]) {
        diagnosticScopeBookmarks = bookmarks
    }
    
    func showIconStyleDiagnostics() {
        do {
            let bookmarks = diagnosticScopeBookmarks
            let total = bookmarks.count
            
            guard !bookmarks.isEmpty else {
                diagnosticReport = DiagnosticReport(
                    title: String(localized: "Icon Style Code Diagnostics"),
                    message: String(localized: "The current list is empty; nothing to diagnose.")
                )
                return
            }
            
            let exactHosts = bookmarks.map { $0.host.lowercased() }
            let alternateHosts = exactHosts.map { host in
                if host.hasPrefix("www.") {
                    return String(host.dropFirst(4))
                }
                return "www." + host
            }
            let rawValueByHost = try store.iconStyleRawValues(for: exactHosts + alternateHosts)
            
            var counts: [Int?: Int] = [:]
            for host in exactHosts {
                let rawValue = rawValueByHost[host] ?? rawValueByHost[alternateHost(for: host)]
                counts[rawValue, default: 0] += 1
            }
            
            let sortedKeys = counts.keys.sorted { lhs, rhs in
                switch (lhs, rhs) {
                case let (.some(a), .some(b)):
                    return a < b
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return false
                }
            }
            
            let lines = sortedKeys.compactMap { rawValue -> String? in
                guard let count = counts[rawValue] else { return nil }
                let rawValueText = rawValue.map(String.init) ?? "missing"
                let meaning: String
                if let rawValue, let style = IconStyle.interpreted(from: rawValue) {
                    meaning = "\(style.debugName) / \(style.localizedLabel)"
                } else if rawValue != nil {
                    meaning = "unknown"
                } else {
                    meaning = "no cache_settings row"
                }
                return "\(rawValueText) -> \(meaning)  \(count) items"
            }
            
            let unknownCount = counts
                .filter { rawValue, _ in
                    guard let rawValue else { return true }
                    return IconStyle.interpreted(from: rawValue) == nil
                }
                .reduce(0) { $0 + $1.value }
            
            var message = """
            \(String(localized: "Scope: Current visible list"))
            \(String(localized: "Source:")) cache_settings.transparency_analysis_result
            \(String(localized: "Total items:")) \(total)
            \(String(localized: "Distinct codes:")) \(sortedKeys.count)
            
            \(lines.joined(separator: "\n"))
            """
            
            if unknownCount > 0 {
                message += "\n\n\(String(localized: "Found unknown-code records:")) \(unknownCount)"
            } else {
                message += "\n\n\(String(localized: "No unknown codes found in the current database."))"
            }
            
            diagnosticReport = DiagnosticReport(
                title: String(localized: "Icon Style Code Diagnostics"),
                message: message
            )
        } catch {
            reportTransient(error, context: "Read icon style code diagnostics")
        }
    }
    
    private func alternateHost(for host: String) -> String {
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return "www." + host
    }
    
    private func userMessage(from error: Error) -> String {
        if let localized = error as? LocalizedError, let desc = localized.errorDescription {
            return desc
        }
        return error.localizedDescription
    }
    
    private func reportTransient(_ error: Error, context: LocalizedStringResource) {
        let message = String(
            localized: "\(context) failed: \(userMessage(from: error))"
        )
        Self.log.error("\(message, privacy: .public)")
        transientError = TransientError(message: message)
    }
}
