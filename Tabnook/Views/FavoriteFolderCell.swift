//
//  FavoriteFolderCell.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import SwiftUI

struct FavoriteFolderCell: View {
    let folder: FavoriteFolder
    let action: () -> Void
    
    @State private var hovering = false
    
    private var previewBookmarks: [FavoriteBookmark] {
        folder.items.compactMap { item in
            if case .bookmark(let bookmark) = item {
                return bookmark
            }
            
            return nil
        }
        .prefix(9)
        .map { $0 }
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                previewIcon
                
                Text(folder.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.tail)
            }
            .frame(width: SiteGridCell.iconBoxSize)
            .padding(.vertical, 10)
            .padding(.horizontal, SiteGridCell.horizontalInset)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
            .fill(.quinary)
            .opacity(hovering ? 1 : 0)
        }
        .onHover {
            hovering = $0
        }
        .animation(
            .easeOut(duration: 0.15),
            value: hovering
        )
        .help(folder.title)
    }
    
    @ViewBuilder
    private var previewIcon: some View {
        if previewBookmarks.isEmpty {
            StandardIconBox(
                size: SiteGridCell.iconBoxSize,
                backgroundColor: .clear
            ) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        } else {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
                .fill(.clear)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                    .stroke(
                        .white.opacity(0.9),
                        lineWidth: 1
                    )
                }

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(22),
                            spacing: 2
                        ),
                        count: 3
                    ),
                    spacing: 2
                ) {
                    ForEach(0..<9, id: \.self) { index in
                        if index < previewBookmarks.count {
                            FolderPreviewIcon(
                                bookmark: previewBookmarks[index]
                            )
                        } else {
                            Color.clear
                                .frame(
                                    width: 22,
                                    height: 22
                                )
                        }
                    }
                }
                .padding(6)
            }
            .frame(
                width: SiteGridCell.iconBoxSize,
                height: SiteGridCell.iconBoxSize,
                alignment: .topTrailing
            )
        }
    }
}

private struct FolderPreviewIcon: View {
    let bookmark: FavoriteBookmark

    @Environment(SiteStore.self) private var store

    @State private var image: CGImage?

    var body: some View {
        StandardIconBox(
            size: 20,
            backgroundColor: .clear
        ) {
            if let image {
                Image(
                    decorative: image,
                    scale: 1,
                    orientation: .up
                )
                .interpolation(.high)
                .resizable()
                .scaledToFill()
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            loadImage()
        }
    }
    
    private func loadImage() {
        let url = store.site(for: bookmark).iconURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        image = IconImageProcessor.makeThumbnail(
            at: url,
            maxPixelSize: 64
        )
    }
}
