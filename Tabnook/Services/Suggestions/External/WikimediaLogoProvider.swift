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

        let name = host
            .replacingOccurrences(
                of: "www.",
                with: ""
            )
            .components(separatedBy: ".")
            .first ?? host

        let queries = [
            "\(name) logo",
            "\(name) icon",
            "\(name) app icon"
        ]

        var results: [IconCandidate] = []

        for query in queries {
            results.append(
                contentsOf: await search(
                    query: query
                )
            )
        }

        var seen = Set<URL>()

        return results.filter {
            seen.insert($0.url).inserted
        }
    }

    private func search(
        query: String
    ) async -> [IconCandidate] {
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
                value: "5"
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

        guard
            let url = components.url,
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
                !imageURL.lowercased().contains(".pdf"),
                !imageURL.lowercased().contains(".svg"),
                let url = URL(string: imageURL)
            else {
                return nil
            }

            return IconCandidate(
                url: url,
                source: .wikimedia,
                score: 450,
                confidence: 70
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
