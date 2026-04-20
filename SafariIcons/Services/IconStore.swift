import Foundation
import CoreGraphics
import ImageIO
import SQLite3
import UniformTypeIdentifiers

enum IconStoreError: LocalizedError {
    case cannotOpenDatabase(String)
    case queryFailed(String)
    case invalidImage
    case cannotEncodeImage

    var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let msg):
            return "Unable to open Safari icon cache database: \(msg)"
        case .queryFailed(let msg):
            return "Database query failed: \(msg)"
        case .invalidImage:
            return "Unable to read the icon file. Please use a common image format and try again."
        case .cannotEncodeImage:
            return "Unable to convert the icon to a Safari-compatible PNG format."
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

enum IconImageProcessor {
    static let storedMaxPixelSize = 512
    static let displayOversampleFactor: CGFloat = 2

    static func normalizedPNGData(from sourceURL: URL) throws -> Data {
        let source = try makeSource(from: sourceURL)
        return try normalizedPNGData(from: source)
    }

    static func normalizedPNGData(from imageData: Data) throws -> Data {
        let source = try makeSource(from: imageData)
        return try normalizedPNGData(from: source)
    }

    static func makeThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = try? makeSource(from: url) else {
            return nil
        }
        return makeDisplayImage(from: source, maxPixelSize: maxPixelSize)
    }

    static func displayMaxPixelSize(for pointSize: CGFloat, scale: CGFloat) -> Int {
        let clampedScale = max(scale, 1)
        return Int(ceil(pointSize * clampedScale * displayOversampleFactor))
    }

    static func sanitizeStoredIcon(at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        guard let source = try? makeSource(from: url) else {
            try? FileManager.default.removeItem(at: url)
            return true
        }

        let metadata = imageMetadata(for: source)
        let needsRewrite = metadata.typeIdentifier != UTType.png.identifier
            || metadata.maxPixelSize > storedMaxPixelSize
            || metadata.width != metadata.height
        guard needsRewrite else {
            return false
        }

        let pngData = try normalizedPNGData(from: source)
        try pngData.write(to: url, options: .atomic)
        return true
    }

    private static func normalizedPNGData(from source: CGImageSource) throws -> Data {
        guard let image = makeStandardizedImage(from: source, maxPixelSize: storedMaxPixelSize) else {
            throw IconStoreError.invalidImage
        }
        return try encodePNG(image)
    }

    private static func makeStandardizedImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard let image = makeDownsampledImage(from: source, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return renderIntoStandardBox(image, canvasPixelSize: maxPixelSize)
    }

    private static func makeDisplayImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let metadata = imageMetadata(for: source)
        if metadata.maxPixelSize > 0, metadata.maxPixelSize <= maxPixelSize {
            return makeFullResolutionImage(from: source)
        }
        return makeDownsampledImage(from: source, maxPixelSize: maxPixelSize)
    }

    private static func makeSource(from url: URL) throws -> CGImageSource {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            throw IconStoreError.invalidImage
        }
        return source
    }

    private static func makeSource(from data: Data) throws -> CGImageSource {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            throw IconStoreError.invalidImage
        }
        return source
    }

    private static func makeDownsampledImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func makeFullResolutionImage(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    private static func renderIntoStandardBox(_ image: CGImage, canvasPixelSize: Int) -> CGImage? {
        let size = CGFloat(canvasPixelSize)
        let canvasRect = CGRect(x: 0, y: 0, width: size, height: size)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: canvasPixelSize,
            height: canvasPixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.clear(canvasRect)
        let cornerRadius = IconBoxGeometry.cornerRadius(for: size)
        let boxPath = CGPath(
            roundedRect: canvasRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(boxPath)
        context.clip()
        context.draw(image, in: aspectFillRect(for: image, in: canvasRect))
        return context.makeImage()
    }

    private static func aspectFillRect(for image: CGImage, in bounds: CGRect) -> CGRect {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        guard imageWidth > 0, imageHeight > 0 else {
            return bounds
        }

        let scale = max(bounds.width / imageWidth, bounds.height / imageHeight)
        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        return CGRect(
            x: bounds.midX - (scaledWidth / 2),
            y: bounds.midY - (scaledHeight / 2),
            width: scaledWidth,
            height: scaledHeight
        )
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw IconStoreError.cannotEncodeImage
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw IconStoreError.cannotEncodeImage
        }
        return data as Data
    }

    private static func imageMetadata(for source: CGImageSource) -> (typeIdentifier: String?, width: Int, height: Int, maxPixelSize: Int) {
        let typeIdentifier = CGImageSourceGetType(source) as String?
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (typeIdentifier, width, height, max(width, height))
    }
}

struct IconStore: Sendable {
    let paths: SafariPaths

    init(paths: SafariPaths = .default) {
        self.paths = paths
    }

    func listSites() throws -> [Site] {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }

        let open = sqlite3_open_v2(paths.db.path, &db, SQLITE_OPEN_READONLY, nil)
        guard open == SQLITE_OK else {
            throw IconStoreError.cannotOpenDatabase(String(cString: sqlite3_errmsg(db)))
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT host, transparency_analysis_result FROM cache_settings"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IconStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        var decorated: [(sortKey: String, site: Site)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cHost = sqlite3_column_text(stmt, 0) else { continue }
            let host = String(cString: cHost)
            guard !host.isEmpty else { continue }
            let rawStyleValue: Int?
            if sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                rawStyleValue = nil
            } else {
                rawStyleValue = Int(sqlite3_column_int(stmt, 1))
            }
            let site = Site(host: host, rawStyleValue: rawStyleValue, paths: paths)
            decorated.append((site.domainName.lowercased(), site))
        }
        decorated.sort { $0.sortKey < $1.sortKey }
        return decorated.map { $0.site }
    }

    func iconStyleValueDistribution() throws -> [IconStyleValueCount] {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }

        let open = sqlite3_open_v2(paths.db.path, &db, SQLITE_OPEN_READONLY, nil)
        guard open == SQLITE_OK else {
            throw IconStoreError.cannotOpenDatabase(String(cString: sqlite3_errmsg(db)))
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT transparency_analysis_result, COUNT(*)
            FROM cache_settings
            GROUP BY transparency_analysis_result
            ORDER BY transparency_analysis_result
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IconStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        var rows: [IconStyleValueCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rawValue: Int?
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL {
                rawValue = nil
            } else {
                rawValue = Int(sqlite3_column_int(stmt, 0))
            }
            let count = Int(sqlite3_column_int64(stmt, 1))
            rows.append(IconStyleValueCount(rawValue: rawValue, count: count))
        }
        return rows
    }

    func iconStyleRawValues(for hosts: [String]) throws -> [String: Int] {
        let uniqueHosts = Array(Set(hosts.map { $0.lowercased() }))
        guard !uniqueHosts.isEmpty else {
            return [:]
        }

        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }

        let open = sqlite3_open_v2(paths.db.path, &db, SQLITE_OPEN_READONLY, nil)
        guard open == SQLITE_OK else {
            throw IconStoreError.cannotOpenDatabase(String(cString: sqlite3_errmsg(db)))
        }

        let placeholders = Array(repeating: "?", count: uniqueHosts.count).joined(separator: ", ")
        let sql = "SELECT host, transparency_analysis_result FROM cache_settings WHERE host IN (\(placeholders))"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IconStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        for (index, host) in uniqueHosts.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), host, -1, SQLITE_TRANSIENT)
        }

        var rows: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cHost = sqlite3_column_text(stmt, 0) else { continue }
            let host = String(cString: cHost).lowercased()
            guard sqlite3_column_type(stmt, 1) != SQLITE_NULL else { continue }
            rows[host] = Int(sqlite3_column_int(stmt, 1))
        }
        return rows
    }

    func setStyle(host: String, style: IconStyle) throws {
        try update(sql: "UPDATE cache_settings SET transparency_analysis_result = ? WHERE host = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(style.rawValue))
            sqlite3_bind_text(stmt, 2, host, -1, SQLITE_TRANSIENT)
        }
    }

    func setIconCached(host: String) throws {
        try update(sql: "UPDATE cache_settings SET icon_is_in_cache = '1' WHERE host = ?") { stmt in
            sqlite3_bind_text(stmt, 1, host, -1, SQLITE_TRANSIENT)
        }
    }

    private func update(sql: String, bind: (OpaquePointer?) -> Void) throws {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard sqlite3_open_v2(paths.db.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw IconStoreError.cannotOpenDatabase(String(cString: sqlite3_errmsg(db)))
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IconStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw IconStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func writeIcon(from source: URL, for site: Site) throws {
        try lockImages(false)
        defer { try? lockImages(true) }

        let destination = paths.iconURL(forMD5: site.md5)
        let normalizedData = try IconImageProcessor.normalizedPNGData(from: source)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try normalizedData.write(to: destination, options: .atomic)
        try? setIconCached(host: site.host)
    }

    func writeIcon(data: Data, for site: Site) throws {
        try lockImages(false)
        defer { try? lockImages(true) }

        let destination = paths.iconURL(forMD5: site.md5)
        let normalizedData = try IconImageProcessor.normalizedPNGData(from: data)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try normalizedData.write(to: destination, options: .atomic)
        try? setIconCached(host: site.host)
    }

    func repairStoredIconsIfNeeded(at urls: [URL]) throws -> Bool {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            return false
        }

        try lockImages(false)
        defer { try? lockImages(true) }

        var repairedAny = false
        for url in existing {
            if try IconImageProcessor.sanitizeStoredIcon(at: url) {
                repairedAny = true
            }
        }
        return repairedAny
    }

    func lockImages(_ locked: Bool) throws {
        try FileManager.default.setAttributes(
            [.immutable: locked],
            ofItemAtPath: paths.images.path
        )
    }

    func resetDefaults() throws {
        try? lockImages(false)
        if FileManager.default.fileExists(atPath: paths.touchIconCache.path) {
            try FileManager.default.removeItem(at: paths.touchIconCache)
        }
    }
}

struct IconStyleValueCount: Sendable {
    let rawValue: Int?
    let count: Int
}
