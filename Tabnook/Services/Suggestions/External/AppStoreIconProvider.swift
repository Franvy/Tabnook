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
        guard
            let host = websiteURL.host
        else {
            return []
        }

        let term = host
            .replacingOccurrences(
                of: "www.",
                with: ""
            )

        guard var components = URLComponents(
            string: "https://itunes.apple.com/search"
        )
        else {
            return []
        }

        components.queryItems = [
            URLQueryItem(
                name: "term",
                value: term
            ),
            URLQueryItem(
                name: "entity",
                value: "software"
            ),
            URLQueryItem(
                name: "limit",
                value: "3"
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
            guard let iconURL = URL(
                string: app.iconURL
            )
            else {
                return nil
            }

            return IconCandidate(
                url: iconURL,
                source: .appStore,
                score: 700,
                declaredSize: 512
            )
        }
    }
}

private struct Response: Decodable {
    let results: [App]
}

private struct App: Decodable {
    let iconURL: String

    enum CodingKeys: String, CodingKey {
        case iconURL = "artworkUrl512"
    }
}
