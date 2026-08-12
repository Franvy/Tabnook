//
//  FavoriteFolderView.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import SwiftUI

struct FavoriteFolderView: View {
    let folder: FavoriteFolder
    let path: String
    
    @Binding var editingBookmarkID: FavoriteBookmark.ID?
    
    @State private var folderStack: [FolderNavigationItem] = []
    @State private var presentedBookmark: FavoriteBookmark?
    
    @Environment(\.dismiss) private var dismiss
    
    init(
        folder: FavoriteFolder,
        path: String? = nil,
        editingBookmarkID: Binding<FavoriteBookmark.ID?>
    ) {
        self.folder = folder
        self.path = path ?? folder.title
        self._editingBookmarkID = editingBookmarkID
    }
    
    var body: some View {
        VStack(spacing: 0) {
            currentFolderContent
        }
        .frame(
            minWidth: 620,
            minHeight: 420,
            alignment: .top
        )
        .sheet(item: $presentedBookmark) { bookmark in
            SiteDetailView(bookmark: bookmark) {
                presentedBookmark = nil
            }
            .frame(
                minWidth: 480,
                minHeight: 500
            )
        }
        .presentationSizing(.fitted)
    }
    
    @ViewBuilder
    private func folderHeader(
        title: String,
        showsCloseButton: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if !showsCloseButton {
                Button {
                    folderStack.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(.regularMaterial)
                        )
                }
                .buttonStyle(.plain)
            }
            if showsCloseButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(.regularMaterial)
                        )
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
    
    private var currentFolder: FavoriteFolder {
        folderStack.last?.folder ?? folder
    }
    
    private var currentTitle: String {
        folderStack.last?.path ?? path
    }
    
    @ViewBuilder
    private var currentFolderContent: some View {
        VStack(spacing: 0) {
            folderHeader(
                title: currentTitle,
                showsCloseButton: folderStack.isEmpty
            )

            Divider()

            folderGrid(currentFolder)
        }
    }
    
    @ViewBuilder
    private func folderGrid(
        _ folder: FavoriteFolder
    ) -> some View {
        SiteGridView(
            items: folder.items,
            editingBookmarkID: $editingBookmarkID,
            onOpenFolder: { childFolder in
                let parentPath = folderStack.last?.path ?? path

                folderStack.append(
                    FolderNavigationItem(
                        folder: childFolder,
                        path: "\(parentPath) / \(childFolder.title)"
                    )
                )
            },
            onOpenBookmark: { bookmark in
                editingBookmarkID = bookmark.id
                presentedBookmark = bookmark
            },
            compact: true
        )
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .frame(
            maxHeight: .infinity,
            alignment: .top
        )
    }
}

private struct FolderNavigationPage: View {
    let folder: FavoriteFolder
    let title: String

    @Binding var editingBookmarkID: FavoriteBookmark.ID?
    @Binding var navigationPath: NavigationPath
    @Binding var presentedBookmark: FavoriteBookmark?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            SiteGridView(
                items: folder.items,
                editingBookmarkID: $editingBookmarkID,
                onOpenFolder: { childFolder in
                    navigationPath.append(
                        FolderNavigationItem(
                            folder: childFolder,
                            path: "\(title) / \(childFolder.title)"
                        )
                    )
                },
                onOpenBookmark: { bookmark in
                    editingBookmarkID = bookmark.id
                    presentedBookmark = bookmark
                },
                compact: true
            )
            .padding(.top, 8)
            .padding(.horizontal, 12)
        }
    }
}

private struct FolderNavigationItem: Hashable {
    let folder: FavoriteFolder
    let path: String
}
