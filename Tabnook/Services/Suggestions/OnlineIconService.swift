//
//  OnlineIconService.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation
import ImageIO

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
        let html = try await fetchHTML(
            from: websiteURL
        )

        var candidates = parser.candidates(
            from: html,
            baseURL: websiteURL
        )

        if let manifestURL = parser.manifestURL(
            from: html,
            baseURL: websiteURL
        ) {
            let manifestCandidates = try? await fetchManifestIcons(
                from: manifestURL
            )

            if let manifestCandidates {
                candidates.append(contentsOf: manifestCandidates)
            }
        }

        candidates = deduplicate(
            candidates
        )

        guard !candidates.isEmpty else {
            throw OnlineIconServiceError.noCandidates
        }

        return await downloadCandidates(
            candidates
        )
    }

    private func fetchHTML(
        from url: URL
    ) async throws -> String {
        let (data, response) = try await session.data(
            from: url
        )

        guard
            let http = response as? HTTPURLResponse,
            (200..<400).contains(http.statusCode),
            let html = String(
                data: data,
                encoding: .utf8
            )
        else {
            throw OnlineIconServiceError.invalidResponse
        }

        return html
    }

    private func fetchManifestIcons(
        from url: URL
    ) async throws -> [IconCandidate] {
        let (data, response) = try await session.data(
            from: url
        )

        guard
            let http = response as? HTTPURLResponse,
            (200..<400).contains(http.statusCode),
            let manifest = try? JSONDecoder().decode(
                WebManifest.self,
                from: data
            )
        else {
            return []
        }

        return manifest.icons.compactMap { icon in
            guard let iconURL = URL(
                string: icon.src,
                relativeTo: url
            )?.absoluteURL
            else {
                return nil
            }

            return IconCandidate(
                url: iconURL,
                source: .manifest,
                score: manifestScore(
                    size: icon.sizes?.first
                ),
                declaredSize: manifestSize(
                    icon.sizes?.first
                )
            )
        }
    }

    private func downloadCandidates(
        _ candidates: [IconCandidate]
    ) async -> [OnlineIconResult] {
        var results: [OnlineIconResult] = []

        for candidate in candidates.prefix(12) {
            guard let (data, response) = try? await session.data(
                from: candidate.url
            ),
            let http = response as? HTTPURLResponse,
            (200..<400).contains(http.statusCode),
            !data.isEmpty,
            isValidImage(data)
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

    private func deduplicate(
        _ candidates: [IconCandidate]
    ) -> [IconCandidate] {
        var seen = Set<URL>()

        return candidates
            .sorted {
                $0.score > $1.score
            }
            .filter {
                seen.insert($0.url).inserted
            }
    }

    private func manifestScore(
        size: String?
    ) -> Int {
        guard let size else {
            return 300
        }

        if size.contains("512") {
            return 600
        }

        if size.contains("192") {
            return 500
        }

        if size.contains("180") {
            return 450
        }

        return 350
    }

    private func manifestSize(
        _ size: String?
    ) -> Int? {
        guard let size else {
            return nil
        }

        return Int(
            size.split(separator: "x").first ?? ""
        )
    }

    private func isValidImage(
        _ data: Data
    ) -> Bool {
        CGImageSourceCreateWithData(
            data as CFData,
            nil
        ) != nil
    }
}

private struct WebManifest: Decodable {
    let icons: [WebManifestIcon]
}

private struct WebManifestIcon: Decodable {
    let src: String
    let sizes: [String]?
}
