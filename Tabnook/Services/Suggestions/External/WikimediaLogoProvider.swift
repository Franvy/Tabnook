//
//  WikimediaLogoProvider.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

struct WikimediaLogoProvider: ExternalIconProvider {
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

        let query = host
            .replacingOccurrences(
                of: "www.",
                with: ""
            )

        guard var components = URLComponents(
            string: "https://commons.wikimedia.org/w/api.php"
        )
        else {
            return []
        }

        components.queryItems = [
            URLQueryItem(
                name: "action",
                value: "query"
            ),
            URLQueryItem(
                name: "generator",
                value: "search"
            ),
            URLQueryItem(
                name: "gsrsearch",
                value: query
            ),
            URLQueryItem(
                name: "gsrnamespace",
                value: "6"
            ),
            URLQueryItem(
                name: "gsrlimit",
                value: "3"
            ),
            URLQueryItem(
                name: "prop",
                value: "imageinfo"
            ),
            URLQueryItem(
                name: "iiprop",
                value: "url"
            ),
            URLQueryItem(
                name: "format",
                value: "json"
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
                    WikimediaResponse.self,
                    from: data
                )
        else {
            return []
        }

        return response.query?.pages.values.compactMap { page in
            guard
                let imageURL = page.imageinfo?.first?.url,
                let url = URL(string: imageURL)
            else {
                return nil
            }

            return IconCandidate(
                url: url,
                source: .wikimedia,
                score: 180
            )
        } ?? []
    }
}

private struct WikimediaResponse: Decodable {
    let query: Query?

    struct Query: Decodable {
        let pages: [String: Page]
    }

    struct Page: Decodable {
        let imageinfo: [ImageInfo]?
    }

    struct ImageInfo: Decodable {
        let url: String
    }
}
