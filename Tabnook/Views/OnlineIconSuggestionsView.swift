//
//  OnlineIconSuggestionsView.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import SwiftUI
import AppKit

struct OnlineIconSuggestionsView: View {
    let site: Site
    let store: SiteStore
    let websiteURL: URL
    let onIconApplied: () -> Void

    @State private var results: [OnlineIconResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested Online")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if isSearching {
                ProgressView()
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if results.isEmpty {
                Button("Search Online") {
                    search()
                }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 72))
                    ],
                    spacing: 12
                ) {
                    ForEach(results) { result in
                        Button {
                            store.acceptDrop(
                                data: result.data,
                                for: site
                            )
                            onIconApplied()
                        } label: {
                            if let image = NSImage(data: result.data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(
                                        width: 64,
                                        height: 64
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func search() {
        isSearching = true
        errorMessage = nil

        Task {
            do {
                let results = try await OnlineIconService()
                    .search(
                        websiteURL: websiteURL
                    )

                await MainActor.run {
                    self.results = results
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSearching = false
                }
            }
        }
    }
}
