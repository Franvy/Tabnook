import SwiftUI

struct SiteGridView: View {
    private static let desiredVisualIconSpacing: CGFloat = 21
    private static let columnSpacing: CGFloat = max(
        0,
        desiredVisualIconSpacing - ((SiteGridCell.layoutWidth - SiteGridCell.iconBoxSize))
    )
    private static let rowSpacing: CGFloat = 12
    
    let items: [FavoriteFolderItem]
    @Binding var editingBookmarkID: FavoriteBookmark.ID?
    
    let onOpenFolder: (FavoriteFolder) -> Void
    let onOpenBookmark: (FavoriteBookmark) -> Void
    let compact: Bool
    
    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: SiteGridCell.layoutWidth,
                    maximum: SiteGridCell.layoutWidth
                ),
                spacing: compact ? 8 : Self.columnSpacing
            )
        ]
    }
    
    var body: some View {
        if items.isEmpty {
            ContentUnavailableView(
                "No Favorites",
                systemImage: "star",
                description: Text("Add sites to Favorites in Safari and their icons will appear here.")
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: compact ? 4 : Self.rowSpacing
                ) {
                    ForEach(items) { item in
                        switch item {
                        case .bookmark(let bookmark):
                            SiteGridCell(
                                bookmark: bookmark,
                                editingBookmarkID: $editingBookmarkID
                            )
                            .simultaneousGesture(
                                TapGesture()
                                    .onEnded {
                                        onOpenBookmark(bookmark)
                                    }
                            )
                            
                        case .folder(let folder):
                            FavoriteFolderCell(
                                folder: folder
                            ) {
                                onOpenFolder(folder)
                            }
                        }
                    }
                }
                .padding(
                    compact ? 16 : 24
                )
                .accessibilityElement(children: .contain)
            }
            .scrollIndicators(.hidden)
        }
    }
}
