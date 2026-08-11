//
//  OnlineIconService.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

struct OnlineIconResult: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let data: Data
}

enum OnlineIconServiceError: LocalizedError {
    case invalidResponse
    case noCandidates
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Unable to read website icon data.")
        case .noCandidates:
            return String(localized: "No online icons found.")
        case .invalidImage:
            return String(localized: "Downloaded icon is not a valid image.")
        }
    }
}

struct OnlineIconService: Sendable {
    private let session: any URLSessioning
    private let parser: WebsiteIconParser

    init(
        session: any URLSessioning = URLSession.shared,
        parser: WebsiteIconParser = WebsiteIconParser()
    ) {
        self.session = session
        self.parser = parser
    }

    func search(
        websiteURL: URL
    ) async throws -> [OnlineIconResult] {
        let (htmlData, response) = try await session.data(
            from: websiteURL
        )

        guard
            let http = response as? HTTPURLResponse,
            (200..<400).contains(http.statusCode),
            let html = String(data: htmlData, encoding: .utf8)
        else {
            throw OnlineIconServiceError.invalidResponse
        }

        let candidates = parser.candidates(
            from: html,
            baseURL: websiteURL
        )

        guard !candidates.isEmpty else {
            throw OnlineIconServiceError.noCandidates
        }

        var results: [OnlineIconResult] = []

        for candidate in candidates.prefix(6) {
            guard let (data, response) = try? await session.data(
                from: candidate.url
            ),
            let http = response as? HTTPURLResponse,
            (200..<400).contains(http.statusCode),
            !data.isEmpty
            else {
                continue
            }

            results.append(
                OnlineIconResult(
                    id: candidate.url,
                    url: candidate.url,
                    data: data
                )
            )
        }

        return results
    }
}
