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
    }

    let id: URL
    let url: URL
    let source: Source
    let score: Int

    init(url: URL, source: Source, score: Int) {
        self.id = url
        self.url = url
        self.source = source
        self.score = score
    }
}
