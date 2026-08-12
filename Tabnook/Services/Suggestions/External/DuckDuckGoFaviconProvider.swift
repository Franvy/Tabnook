//
//  DuckDuckGoFaviconProvider.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

struct DuckDuckGoFaviconProvider: ExternalIconProvider {
    func candidates(
        for websiteURL: URL
    ) async -> [IconCandidate] {
        guard let host = websiteURL.host else {
            return []
        }

        guard let url = URL(
            string: "https://icons.duckduckgo.com/ip3/\(host).ico"
        )
        else {
            return []
        }

        return [
            IconCandidate(
                url: url,
                source: .duckDuckGoFavicon,
                score: 220
            )
        ]
    }
}
