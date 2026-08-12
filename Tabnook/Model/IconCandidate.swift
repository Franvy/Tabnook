//
//  IconCandidate.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

struct IconCandidate: Identifiable, Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        case appleTouchIcon
        case favicon
        case manifest
        case openGraph
        case twitterCard
        case googleFavicon
        case duckDuckGoFavicon
        case wikimedia
        case appStore
        case playStore
        case fallback
        case imageSource
        case microsoftTile
    }

    let id: URL
    let url: URL
    let source: Source
    let score: Int
    let declaredSize: Int?

    init(
        url: URL,
        source: Source,
        score: Int,
        declaredSize: Int? = nil
    ) {
        self.id = url
        self.url = url
        self.source = source
        self.score = score
        self.declaredSize = declaredSize
    }
}
