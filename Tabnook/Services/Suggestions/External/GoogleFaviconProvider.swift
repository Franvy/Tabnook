//
//  GoogleFaviconProvider.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

struct GoogleFaviconProvider: ExternalIconProvider {
    func candidates(
        for websiteURL: URL
    ) async -> [IconCandidate] {
        guard let host = websiteURL.host else {
            return []
        }

        guard let url = URL(
            string: "https://www.google.com/s2/favicons?domain=\(host)&sz=256"
        )
        else {
            return []
        }

        return [
            IconCandidate(
                url: url,
                source: .googleFavicon,
                score: 250,
                declaredSize: 256
            )
        ]
    }
}
