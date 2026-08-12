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
        let html = try? await fetchHTML(
            from: websiteURL
        )

        var candidates: [IconCandidate] = []

        if let html {
            candidates.append(
                contentsOf: parser.candidates(
                    from: html,
                    baseURL: websiteURL
                )
            )

            if let manifestURL = parser.manifestURL(
                from: html,
                baseURL: websiteURL
            ) {
                let manifestCandidates = try? await fetchManifestIcons(
                    from: manifestURL
                )

                candidates.append(
                    contentsOf: manifestCandidates ?? []
                )
            }
        }

        candidates.append(
            contentsOf: fallbackCandidates(
                websiteURL
            )
        )

        let results = await downloadCandidates(
            candidates
        )

        guard !results.isEmpty else {
            throw OnlineIconServiceError.noCandidates
        }

        return results
    }

    private func fetchHTML(
        from url: URL
    ) async throws -> String {
        var request = URLRequest(url: url)

        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        request.setValue(
            "text/html,application/xhtml+xml",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await session.data(
            for: request
        )

        guard
            let http = response as? HTTPURLResponse,
            (200..<400).contains(http.statusCode)
        else {
            throw OnlineIconServiceError.invalidResponse
        }

        if let html = String(
            data: data,
            encoding: .utf8
        ) {
            return html
        }

        if let html = String(
            data: data,
            encoding: .isoLatin1
        ) {
            return html
        }

        throw OnlineIconServiceError.invalidResponse
    }

    private func fetchManifestIcons(
        from url: URL
    ) async throws -> [IconCandidate] {
        let request = URLRequest(url: url)

        let (data, _) = try await session.data(
            for: request
        )

        guard let manifest = try? JSONDecoder().decode(
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
                score: score(
                    sizes: icon.sizes,
                    purpose: icon.purpose
                ),
                declaredSize: declaredSize(
                    icon.sizes
                )
            )
        }
    }

    private func fallbackCandidates(
        _ url: URL
    ) -> [IconCandidate] {
        guard let origin = URL(
            string: "\(url.scheme ?? "https")://\(url.host ?? "")"
        )
        else {
            return []
        }

        return [
            "/apple-touch-icon.png",
            "/apple-touch-icon-precomposed.png",
            "/apple-touch-icon-180x180.png",
            "/apple-touch-icon-152x152.png",
            "/android-chrome-512x512.png",
            "/android-chrome-192x192.png",
            "/web-app-manifest-512x512.png",
            "/web-app-manifest-192x192.png",
            "/mstile-310x310.png",
            "/mstile-150x150.png",
            "/favicon-512x512.png",
            "/favicon-192x192.png",
            "/favicon-96x96.png",
            "/favicon.png",
            "/favicon.ico",
            "/icon-512.png",
            "/icon-192.png",
            "/icon.png",
            "/icons/icon-512.png",
            "/icons/icon-192.png",
            "/logo-512.png",
            "/logo.png"
        ]
        .compactMap {
            URL(
                string: $0,
                relativeTo: origin
            )?.absoluteURL
        }
        .map {
            IconCandidate(
                url: $0,
                source: .fallback,
                score: 100
            )
        }
    }

    private func downloadCandidates(
        _ candidates: [IconCandidate]
    ) async -> [OnlineIconResult] {
        var results: [OnlineIconResult] = []
        var seen = Set<URL>()

        for candidate in candidates.sorted(
            by: { $0.score > $1.score }
        ) {
            guard seen.insert(candidate.url).inserted else {
                continue
            }
            
            guard
                let (data, response) = try? await session.data(
                    for: URLRequest(url: candidate.url)
                ),
                let http = response as? HTTPURLResponse,
                (200..<400).contains(http.statusCode),
                let dimensions = imageDimensions(data),
                dimensions.width == dimensions.height
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

    private func imageDimensions(
        _ data: Data
    ) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0,
            height > 0
        else {
            return nil
        }

        return (width, height)
    }

    private func score(
        sizes: String?,
        purpose: String?
    ) -> Int {
        let size = declaredSize(sizes)

        var score: Int

        switch size {
        case let value? where value >= 512:
            score = 700

        case let value? where value >= 256:
            score = 650

        case let value? where value >= 192:
            score = 600

        case let value? where value >= 180:
            score = 550

        case let value? where value >= 128:
            score = 500

        case let value? where value >= 64:
            score = 450

        default:
            score = 350
        }

        if purpose?
            .lowercased()
            .split(separator: " ")
            .contains("maskable") == true {
            score += 150
        }

        return score
    }

    private func declaredSize(
        _ sizes: String?
    ) -> Int? {
        guard let sizes else {
            return nil
        }

        return sizes
            .split(whereSeparator: \.isWhitespace)
            .compactMap { size -> Int? in
                let components = size.split(separator: "x")

                guard
                    components.count == 2,
                    let width = Int(components[0]),
                    let height = Int(components[1]),
                    width == height
                else {
                    return nil
                }

                return width
            }
            .max()
    }
}

private struct WebManifest: Decodable {
    let icons: [WebManifestIcon]
}

private struct WebManifestIcon: Decodable {
    let src: String
    let sizes: String?
    let purpose: String?
    let type: String?
}
