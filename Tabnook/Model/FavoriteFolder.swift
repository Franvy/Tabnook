//
//  FavoriteFolder.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

struct FavoriteFolder: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [FavoriteFolderItem]
    let bookmarksBarIndex: Int
}

enum FavoriteFolderItem: Identifiable, Hashable, Sendable {
    case bookmark(FavoriteBookmark)
    case folder(FavoriteFolder)

    var id: String {
        switch self {
        case .bookmark(let bookmark):
            return bookmark.id
        case .folder(let folder):
            return folder.id
        }
    }
}
