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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)

                Text(folder.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
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
}
