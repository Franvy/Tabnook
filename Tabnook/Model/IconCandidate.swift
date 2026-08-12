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
    let confidence: Int
    let declaredSize: Int?

    init(
        url: URL,
        source: Source,
        score: Int,
        confidence: Int = 100,
        declaredSize: Int? = nil
    ) {
        self.id = url
        self.url = url
        self.source = source
        self.score = score
        self.confidence = confidence
        self.declaredSize = declaredSize
    }
}
