import Foundation
import CryptoKit
import AppKit
import os

enum BackupSourceKind: String, Codable, Sendable {
    case file
    case dropData
}

struct BackupEntry: Codable, Sendable {
    let md5: String
    let sha256: String
    let sizeBytes: Int
    let createdAt: Date
    var updatedAt: Date
    let originalSourceKind: BackupSourceKind
}

struct BackupManifest: Codable, Sendable {
    var schemaVersion: Int
    var updatedAt: Date
    var entries: [String: BackupEntry]

    static let currentSchemaVersion = 1

    static let empty = BackupManifest(
        schemaVersion: currentSchemaVersion,
        updatedAt: Date(),
        entries: [:]
    )
}

struct ReconcileReport: Sendable {
    var restoredHosts: [String] = []
    var skipped: [String] = []
    var droppedStaleEntries: [String] = []
    var schemaTooNew = false
}

enum BackupStoreError: LocalizedError {
    case schemaTooNew(Int)
    case sourceNotReadable(URL)

    var errorDescription: String? {
        switch self {
        case .schemaTooNew(let version):
            return String(localized: "Backup was written by a newer Tabnook (schema v\(version)); restore paused to avoid data loss.")
        case .sourceNotReadable(let url):
            return String(localized: "Unable to read backup file at \(url.path).")
        }
    }
}

actor BackupStore {
    private var rootURL: URL
    private var isSecurityScoped: Bool
    private let safariPaths: SafariPaths

    private static let log = Logger(subsystem: "com.franvy.Tabnook", category: "BackupStore")

    init(safariPaths: SafariPaths = .default) {
        self.safariPaths = safariPaths
        let resolved = BackupPaths.resolveRootURL()
        self.rootURL = resolved.url
        self.isSecurityScoped = resolved.isSecurityScoped
        if resolved.isSecurityScoped {
            _ = resolved.url.startAccessingSecurityScopedResource()
        }
    }

    deinit {
        if isSecurityScoped {
            rootURL.stopAccessingSecurityScopedResource()
        }
    }

    var currentRootURL: URL { rootURL }
    var iconsURL: URL { rootURL.appendingPathComponent(BackupPaths.iconsSubfolder, isDirectory: true) }
    var manifestURL: URL { rootURL.appendingPathComponent(BackupPaths.manifestFilename) }

    func loadManifest() throws -> BackupManifest {
        try ensureDirectories()
        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try decoder.decode(BackupManifest.self, from: data)
        return manifest
    }

    @discardableResult
    func recordBackup(host: String, pngData: Data, md5: String, sourceKind: BackupSourceKind) throws -> BackupEntry {
        try ensureDirectories()
        let normalizedHost = host.lowercased()
        var manifest = try loadManifestTolerant()
        let iconPath = iconFileURL(forMD5: md5)

        try atomicWrite(data: pngData, to: iconPath)

        let shaDigest = SHA256.hash(data: pngData)
        let shaHex = shaDigest.map { String(format: "%02x", $0) }.joined()
        let now = Date()

        let entry: BackupEntry
        if var existing = manifest.entries[normalizedHost] {
            existing.updatedAt = now
            let updated = BackupEntry(
                md5: md5,
                sha256: shaHex,
                sizeBytes: pngData.count,
                createdAt: existing.createdAt,
                updatedAt: now,
                originalSourceKind: existing.originalSourceKind
            )
            manifest.entries[normalizedHost] = updated
            entry = updated
        } else {
            entry = BackupEntry(
                md5: md5,
                sha256: shaHex,
                sizeBytes: pngData.count,
                createdAt: now,
                updatedAt: now,
                originalSourceKind: sourceKind
            )
            manifest.entries[normalizedHost] = entry
        }
        manifest.updatedAt = now
        manifest.schemaVersion = BackupManifest.currentSchemaVersion
        try persistManifest(manifest)
        return entry
    }

    func forget(host: String) throws {
        var manifest = try loadManifestTolerant()
        let key = host.lowercased()
        guard let entry = manifest.entries.removeValue(forKey: key) else { return }
        let iconPath = iconFileURL(forMD5: entry.md5)
        if FileManager.default.fileExists(atPath: iconPath.path) {
            try? FileManager.default.removeItem(at: iconPath)
        }
        manifest.updatedAt = Date()
        try persistManifest(manifest)
    }

    func forgetAll() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: iconsURL.path) {
            try fm.removeItem(at: iconsURL)
        }
        try persistManifest(.empty)
    }

    func reconcile(iconStore: IconStore) async throws -> ReconcileReport {
        try ensureDirectories()
        var report = ReconcileReport()

        let rawManifest: BackupManifest
        do {
            rawManifest = try loadManifest()
        } catch {
            Self.log.error("reconcile: failed to load manifest: \(error.localizedDescription, privacy: .public)")
            return report
        }

        if rawManifest.schemaVersion > BackupManifest.currentSchemaVersion {
            report.schemaTooNew = true
            Self.log.error("reconcile: manifest schema \(rawManifest.schemaVersion, privacy: .public) newer than supported \(BackupManifest.currentSchemaVersion, privacy: .public)")
            return report
        }

        var manifest = rawManifest
        var manifestChanged = false

        for host in manifest.entries.keys.sorted() {
            guard let entry = manifest.entries[host] else { continue }
            let backupIconURL = iconFileURL(forMD5: entry.md5)
            let safariIconURL = safariPaths.iconURL(forMD5: entry.md5)

            let fm = FileManager.default
            guard fm.fileExists(atPath: backupIconURL.path) else {
                manifest.entries.removeValue(forKey: host)
                report.droppedStaleEntries.append(host)
                manifestChanged = true
                continue
            }

            if isICloudPlaceholder(backupIconURL) {
                Self.log.debug("reconcile: skipping \(host, privacy: .public) — backup is iCloud placeholder")
                continue
            }

            if !fm.fileExists(atPath: safariIconURL.path) {
                do {
                    try iconStore.restoreIconFile(from: backupIconURL, to: safariIconURL)
                    report.restoredHosts.append(host)
                } catch {
                    Self.log.error("reconcile: restore failed for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            do {
                let safariSha = try sha256OfFile(at: safariIconURL)
                if safariSha == entry.sha256 {
                    report.skipped.append(host)
                } else {
                    try iconStore.restoreIconFile(from: backupIconURL, to: safariIconURL)
                    report.restoredHosts.append(host)
                }
            } catch {
                Self.log.error("reconcile: hash/restore error for \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if manifestChanged {
            manifest.updatedAt = Date()
            try? persistManifest(manifest)
        }

        return report
    }

    func revealInFinder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootURL.path) {
            try? ensureDirectories()
        }
        NSWorkspace.shared.activateFileViewerSelecting([rootURL])
    }

    func setRootURL(_ newURL: URL, migrateExisting: Bool) throws {
        let fm = FileManager.default
        let newRoot = newURL
        let newIcons = newRoot.appendingPathComponent(BackupPaths.iconsSubfolder, isDirectory: true)
        let newManifest = newRoot.appendingPathComponent(BackupPaths.manifestFilename)

        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: newIcons, withIntermediateDirectories: true)

        if migrateExisting {
            if fm.fileExists(atPath: iconsURL.path) {
                let contents = (try? fm.contentsOfDirectory(at: iconsURL, includingPropertiesForKeys: nil)) ?? []
                for item in contents {
                    let target = newIcons.appendingPathComponent(item.lastPathComponent)
                    if fm.fileExists(atPath: target.path) {
                        try? fm.removeItem(at: target)
                    }
                    try? fm.copyItem(at: item, to: target)
                }
            }
            if fm.fileExists(atPath: manifestURL.path), !fm.fileExists(atPath: newManifest.path) {
                try? fm.copyItem(at: manifestURL, to: newManifest)
            }
        }

        try BackupPaths.storeBookmark(for: newURL)

        if isSecurityScoped {
            rootURL.stopAccessingSecurityScopedResource()
        }
        rootURL = newURL
        isSecurityScoped = true
        _ = newURL.startAccessingSecurityScopedResource()
    }

    func resetToDefaultRoot() throws {
        if isSecurityScoped {
            rootURL.stopAccessingSecurityScopedResource()
        }
        BackupPaths.clearBookmark()
        rootURL = BackupPaths.defaultRootURL()
        isSecurityScoped = false
        try ensureDirectories()
    }

    private func loadManifestTolerant() throws -> BackupManifest {
        do {
            return try loadManifest()
        } catch {
            Self.log.error("loadManifest failed (\(error.localizedDescription, privacy: .public)); starting fresh manifest")
            return .empty
        }
    }

    private func ensureDirectories() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootURL.path) {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: iconsURL.path) {
            try fm.createDirectory(at: iconsURL, withIntermediateDirectories: true)
        }
    }

    private func persistManifest(_ manifest: BackupManifest) throws {
        let data = try encoder.encode(manifest)
        try atomicWrite(data: data, to: manifestURL)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }
    }

    private func iconFileURL(forMD5 md5: String) -> URL {
        iconsURL.appendingPathComponent("\(md5).png")
    }

    private func isICloudPlaceholder(_ url: URL) -> Bool {
        let resourceValues = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = resourceValues?.ubiquitousItemDownloadingStatus else {
            return false
        }
        return status != .current
    }

    private func sha256OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = try handle.read(upToCount: 1 << 16) ?? Data(), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
