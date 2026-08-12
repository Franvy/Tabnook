//
//  AppStoreIconProvider.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

struct AppStoreIconProvider: ExternalIconProvider {
    private let session: any URLSessioning

    init(
        session: any URLSessioning = URLSession.shared
    ) {
        self.session = session
    }

    func candidates(
        for websiteURL: URL
    ) async -> [IconCandidate] {
        guard let host = websiteURL.host else {
            return []
        }

        let domain = host
            .replacingOccurrences(
                of: "www.",
                with: ""
            )
            .lowercased()

        let brandName = domain
            .split(separator: ".")
            .first
            .map(String.init) ?? domain

        guard var components = URLComponents(
            string: "https://itunes.apple.com/search"
        )
        else {
            return []
        }

        components.queryItems = [
            URLQueryItem(
                name: "term",
                value: brandName
            ),
            URLQueryItem(
                name: "entity",
                value: "software"
            ),
            URLQueryItem(
                name: "limit",
                value: "10"
            )
        ]

        guard let url = components.url else {
            return []
        }

        guard
            let (data, _) = try? await session.data(
                for: URLRequest(url: url)
            ),
            let response = try? JSONDecoder()
                .decode(
                    Response.self,
                    from: data
                )
        else {
            return []
        }

        return response.results.compactMap { app in
            guard
                let iconURL = URL(
                    string: app.iconURL
                ),
                let confidence = confidence(
                    for: app,
                    domain: domain,
                    brandName: brandName
                ),
                confidence >= 70
            else {
                return nil
            }

            return IconCandidate(
                url: iconURL,
                source: .appStore,
                score: 700,
                confidence: confidence,
                declaredSize: 512
            )
        }
    }

    private func confidence(
        for app: App,
        domain: String,
        brandName: String
    ) -> Int? {
        let searchableText = [
            app.trackName,
            app.sellerName,
            app.bundleID,
            app.trackViewURL
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        if searchableText.contains(domain) {
            return 100
        }

        if searchableText.contains(brandName) {
            return 75
        }

        return nil
    }
}

private struct Response: Decodable {
    let results: [App]
}

private struct App: Decodable {
    let iconURL: String
    let trackName: String?
    let sellerName: String?
    let bundleID: String?
    let trackViewURL: String?

    enum CodingKeys: String, CodingKey {
        case iconURL = "artworkUrl512"
        case trackName
        case sellerName
        case bundleID = "bundleId"
        case trackViewURL = "trackViewUrl"
    }
}
