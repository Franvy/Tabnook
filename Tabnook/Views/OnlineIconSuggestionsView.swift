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

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if results.isEmpty && isSearching {
                ProgressView()
                    .frame(
                        width: 64,
                        height: 64
                    )
            }

            if results.isEmpty && !isSearching && errorMessage == nil {
                ProgressView()
            }

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
                        if let image = NSImage(
                            data: result.data
                        ) {
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

                if isSearching && !results.isEmpty {
                    ProgressView()
                        .frame(
                            width: 64,
                            height: 64
                        )
                }
            }
        }
        .task {
            await searchAutomatically()
        }
    }

    private func searchAutomatically() async {
        guard results.isEmpty else {
            return
        }

        isSearching = true
        errorMessage = nil

        do {
            for try await result in OnlineIconService()
                .stream(
                    websiteURL: websiteURL
                ) {
                if !results.contains(
                    where: { $0.id == result.id }
                ) {
                    results.append(result)
                }
            }

            isSearching = false
        } catch {
            errorMessage = error.localizedDescription
            isSearching = false
        }
    }
}
