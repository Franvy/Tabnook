import Foundation
import CryptoKit
import os

struct FavoriteBookmark: Identifiable, Hashable, Sendable {
    let id: String
    let urlString: String
    let host: String
    let title: String
    let md5: String
    let iconURL: URL
    let bookmarksBarIndex: Int
}

struct BookmarksResult: Sendable {
    var bookmarks: [FavoriteBookmark]
    var rootItems: [FavoriteFolderItem]
    var foundBookmarksBar: Bool
    var topLevelChildCount: Int
    var subfolderCount: Int
}

enum BookmarksReaderError: LocalizedError {
    case permissionDenied(path: String, underlying: Error)
    case malformed

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let path, let underlying):
            return String(localized: "Unable to read \(path) (permission denied). Please authorize access to the ~/Library/Safari/ folder. Underlying error: \(underlying.localizedDescription)")
        case .malformed:
            return String(localized: "Bookmarks.plist parse failed or structure was unexpected.")
        }
    }
}

enum BookmarksWriterError: LocalizedError {
    case bookmarkNotFound
    case malformed
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .bookmarkNotFound:
            return String(localized: "Could not find this favorite inside Bookmarks.plist.")
        case .malformed:
            return String(localized: "Bookmarks.plist had an unexpected structure.")
        case .writeFailed(let underlying):
            return String(localized: "Unable to save to Bookmarks.plist: \(underlying.localizedDescription)")
        }
    }
}

enum BookmarksWriter {
    static func renameFavorite(_ bookmark: FavoriteBookmark, newTitle: String, paths: SafariPaths = .default) throws {
        let url = paths.safari.appendingPathComponent("Bookmarks.plist")
        let data = try Data(contentsOf: url)

        var format: PropertyListSerialization.PropertyListFormat = .binary
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainers],
            format: &format
        )

        guard let root = parsed as? NSMutableDictionary else {
            throw BookmarksWriterError.malformed
        }

        guard renameInBookmarksBar(root: root, bookmark: bookmark, newTitle: newTitle) else {
            throw BookmarksWriterError.bookmarkNotFound
        }

        let out: Data
        do {
            out = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        } catch {
            throw BookmarksWriterError.writeFailed(underlying: error)
        }

        do {
            try out.write(to: url, options: .atomic)
        } catch {
            throw BookmarksWriterError.writeFailed(underlying: error)
        }
    }

    private static func renameInBookmarksBar(root: NSMutableDictionary, bookmark: FavoriteBookmark, newTitle: String) -> Bool {
        guard let bar = findBookmarksBar(in: root) else { return false }
        guard let children = bar["Children"] as? NSArray else { return false }
        guard let child = findBookmarkNode(in: children, matching: bookmark) else { return false }

        if let dict = child["URIDictionary"] as? NSMutableDictionary {
            dict["title"] = newTitle
        } else {
            child["URIDictionary"] = NSMutableDictionary(dictionary: ["title": newTitle])
        }
        if child["Title"] != nil {
            child["Title"] = newTitle
        }
        return true
    }

    private static func findBookmarksBar(in node: NSDictionary) -> NSMutableDictionary? {
        if (node["Title"] as? String) == "BookmarksBar", let mutable = node as? NSMutableDictionary {
            return mutable
        }
        if let children = node["Children"] as? NSArray {
            for case let child as NSDictionary in children {
                if let found = findBookmarksBar(in: child) {
                    return found
                }
            }
        }
        return nil
    }

    private static func findBookmarkNode(in children: NSArray, matching bookmark: FavoriteBookmark) -> NSMutableDictionary? {
        if let bookmarkUUID = bookmarkUUID(fromBookmarkID: bookmark.id) {
            for case let child as NSMutableDictionary in children {
                guard isLeaf(child) else { continue }
                if (child["WebBookmarkUUID"] as? String) == bookmarkUUID {
                    return child
                }
            }
        }

        if let child = childAtBookmarksBarIndex(bookmark.bookmarksBarIndex, in: children),
           isLeaf(child),
           (child["URLString"] as? String) == bookmark.urlString {
            return child
        }

        let matchingURLNodes = children.compactMap { rawChild -> NSMutableDictionary? in
            guard let child = rawChild as? NSMutableDictionary,
                  isLeaf(child),
                  (child["URLString"] as? String) == bookmark.urlString
            else {
                return nil
            }
            return child
        }

        if matchingURLNodes.count == 1 {
            return matchingURLNodes[0]
        }

        let matchingTitleNodes = matchingURLNodes.filter {
            extractTitle(from: $0 as NSDictionary) == bookmark.title
        }
        if matchingTitleNodes.count == 1 {
            return matchingTitleNodes[0]
        }

        return nil
    }

    private static func bookmarkUUID(fromBookmarkID bookmarkID: String) -> String? {
        guard bookmarkID.hasPrefix("uuid:") else { return nil }
        return String(bookmarkID.dropFirst("uuid:".count))
    }

    private static func childAtBookmarksBarIndex(_ index: Int, in children: NSArray) -> NSMutableDictionary? {
        guard index >= 0, index < children.count else { return nil }
        return children[index] as? NSMutableDictionary
    }

    private static func isLeaf(_ node: NSDictionary) -> Bool {
        (node["WebBookmarkType"] as? String) == "WebBookmarkTypeLeaf"
    }

    private static func extractTitle(from node: NSDictionary) -> String? {
        if let uri = node["URIDictionary"] as? NSDictionary,
           let title = uri["title"] as? String,
           !title.isEmpty {
            return title
        }
        if let title = node["Title"] as? String, !title.isEmpty {
            return title
        }
        return nil
    }
}

struct BookmarksReader {
    private static let log = Logger(subsystem: "com.franvy.Tabnook", category: "BookmarksReader")

    static func loadFavorites(paths: SafariPaths = .default) throws -> BookmarksResult {
        let url = paths.safari.appendingPathComponent("Bookmarks.plist")

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.error("Failed to read Bookmarks.plist: \(error.localizedDescription, privacy: .public)")
            throw BookmarksReaderError.permissionDenied(path: url.path, underlying: error)
        }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw BookmarksReaderError.malformed
        }

        guard let root = plist as? [String: Any] else {
            throw BookmarksReaderError.malformed
        }

        guard let bar = findFolder(named: "BookmarksBar", in: root) else {
            log.info("BookmarksBar folder not found in plist")
            return BookmarksResult(
                bookmarks: [],
                rootItems: [],
                foundBookmarksBar: false,
                topLevelChildCount: 0,
                subfolderCount: 0
            )
        }

        let children = (bar["Children"] as? [[String: Any]]) ?? []
        var bookmarks: [FavoriteBookmark] = []
        var rootItems: [FavoriteFolderItem] = []
        var subfolderCount = 0
        var fallbackIDOccurrences: [String: Int] = [:]
        
        for (index, child) in children.enumerated() {
            let type = child["WebBookmarkType"] as? String

            if type == "WebBookmarkTypeList" {
                subfolderCount += 1

                if let folder = parseFolder(
                    child,
                    paths: paths,
                    fallbackIDOccurrences: &fallbackIDOccurrences
                ) {
                    rootItems.append(
                        .folder(folder)
                    )

                    bookmarks.append(
                        contentsOf: flattenBookmarks(
                            folder.items
                        )
                    )
                }

                continue
            }

            if let bookmark = parseBookmark(
                child,
                index: index,
                paths: paths,
                fallbackIDOccurrences: &fallbackIDOccurrences
            ) {
                rootItems.append(
                    .bookmark(bookmark)
                )

                bookmarks.append(bookmark)
            }
        }
        
        log.info("BookmarksBar: topLevelChildren=\(children.count, privacy: .public) leafs=\(bookmarks.count, privacy: .public) subfolders=\(subfolderCount, privacy: .public)")
        if !bookmarks.isEmpty {
            let sample = bookmarks.prefix(5).map { "\($0.title)<\($0.host)>" }.joined(separator: ", ")
            log.info("first 5: \(sample, privacy: .public)")
        }

        return BookmarksResult(
            bookmarks: bookmarks,
            rootItems: rootItems,
            foundBookmarksBar: true,
            topLevelChildCount: children.count,
            subfolderCount: subfolderCount
        )
    }
    
    private static func flattenBookmarks(
        _ items: [FavoriteFolderItem]
    ) -> [FavoriteBookmark] {
        items.flatMap { item in
            switch item {
            case .bookmark(let bookmark):
                return [bookmark]

            case .folder(let folder):
                return flattenBookmarks(folder.items)
            }
        }
    }
    
    private static func parseFolder(
        _ node: [String: Any],
        paths: SafariPaths,
        fallbackIDOccurrences: inout [String: Int]
    ) -> FavoriteFolder? {
        guard
            let title = node["Title"] as? String,
            let children = node["Children"] as? [[String: Any]]
        else {
            return nil
        }

        var items: [FavoriteFolderItem] = []

        for (index, child) in children.enumerated() {
            let type = child["WebBookmarkType"] as? String

            if type == "WebBookmarkTypeList",
               let folder = parseFolder(
                    child,
                    paths: paths,
                    fallbackIDOccurrences: &fallbackIDOccurrences
               ) {
                items.append(.folder(folder))
                continue
            }

            guard let bookmark = parseBookmark(
                child,
                index: index,
                paths: paths,
                fallbackIDOccurrences: &fallbackIDOccurrences
            )
            else {
                continue
            }

            items.append(.bookmark(bookmark))
        }

        return FavoriteFolder(
            id: "folder:\(title)",
            title: title,
            items: items,
            bookmarksBarIndex: 0
        )
    }
    
    private static func parseBookmark(
        _ child: [String: Any],
        index: Int,
        paths: SafariPaths,
        fallbackIDOccurrences: inout [String: Int]
    ) -> FavoriteBookmark? {
        guard
            child["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
            let urlString = child["URLString"] as? String,
            let parsed = URL(string: urlString),
            let rawHost = parsed.host,
            !rawHost.isEmpty
        else {
            return nil
        }

        let title = extractTitle(from: child) ?? fallbackTitle(for: rawHost)
        let md5 = md5Hex(rawHost)

        let fallbackIDBase = fallbackBookmarkIDBase(
            urlString: urlString,
            title: title
        )

        let occurrence = fallbackIDOccurrences[fallbackIDBase] ?? 0
        fallbackIDOccurrences[fallbackIDBase] = occurrence + 1
        
        return FavoriteBookmark(
            id: bookmarkID(
                from: child,
                fallbackIDBase: fallbackIDBase,
                fallbackOccurrence: occurrence
            ),
            urlString: urlString,
            host: rawHost,
            title: title,
            md5: md5,
            iconURL: paths.iconURL(forMD5: md5),
            bookmarksBarIndex: index
        )
    }

    private static func findFolder(named name: String, in node: [String: Any]) -> [String: Any]? {
        if (node["Title"] as? String) == name { return node }
        if let children = node["Children"] as? [[String: Any]] {
            for child in children {
                if let found = findFolder(named: name, in: child) { return found }
            }
        }
        return nil
    }

    private static func extractTitle(from node: [String: Any]) -> String? {
        if let uri = node["URIDictionary"] as? [String: Any],
           let title = uri["title"] as? String,
           !title.isEmpty {
            return title
        }
        if let title = node["Title"] as? String, !title.isEmpty {
            return title
        }
        return nil
    }

    private static func bookmarkID(from node: [String: Any], fallbackIDBase: String, fallbackOccurrence: Int) -> String {
        if let uuid = node["WebBookmarkUUID"] as? String, !uuid.isEmpty {
            return "uuid:\(uuid)"
        }
        return "fallback:\(fallbackIDBase)#\(fallbackOccurrence)"
    }

    private static func fallbackBookmarkIDBase(urlString: String, title: String) -> String {
        md5Hex("\(urlString)\u{1F}\(title)")
    }

    private static func fallbackTitle(for host: String) -> String {
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let parts = stripped.split(separator: ".")
        guard parts.count >= 2 else { return stripped }
        return String(parts[parts.count - 2]).capitalized
    }

    private static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02hhX", $0) }.joined()
    }
}
