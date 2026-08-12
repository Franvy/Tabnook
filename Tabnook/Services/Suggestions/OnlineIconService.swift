//
//  OnlineIconService.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct OnlineIconResult: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let data: Data
    let score: Int
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
    private let externalProviders: [any ExternalIconProvider]
    
    init(
        session: any URLSessioning = URLSession(
            configuration: {
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 5
                configuration.timeoutIntervalForResource = 10
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                return configuration
            }()
        ),
        parser: WebsiteIconParser = WebsiteIconParser(),
        externalProviders: [any ExternalIconProvider] = [
            AppStoreIconProvider(),
            GoogleFaviconProvider(),
            DuckDuckGoFaviconProvider(),
            WikimediaLogoProvider()
        ]
    ) {
        self.session = session
        self.parser = parser
        self.externalProviders = externalProviders
    }
    
    private func secureURL(
        _ url: URL
    ) -> URL {
        guard
            url.scheme?.lowercased() == "http",
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else {
            return url
        }

        components.scheme = "https"

        return components.url ?? url
    }
    
    func stream(
        websiteURL: URL
    ) -> AsyncThrowingStream<OnlineIconResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let websiteURL = secureURL(
                    websiteURL
                )

                do {
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

                    for provider in externalProviders {
                        candidates.append(
                            contentsOf: await provider.candidates(
                                for: websiteURL
                            )
                        )
                    }

                    try await downloadCandidates(
                        candidates
                    ) { result in
                        continuation.yield(result)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: error
                    )
                }
            }
        }
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
        _ candidates: [IconCandidate],
        onResult: @escaping @Sendable (OnlineIconResult) -> Void
    ) async throws {
        var seen = Set<URL>()
        var perceptualHashes: [UInt64] = []

        for candidate in candidates
            .sorted(by: {
                rankedScore($0) > rankedScore($1)
            })
            .prefix(30) {

            let candidateURL = secureURL(
                candidate.url
            )

            guard !looksLikeBanner(candidateURL) else {
                continue
            }

            guard seen.insert(candidateURL).inserted else {
                continue
            }

            guard
                let (data, response) = try? await session.data(
                    for: URLRequest(url: candidateURL)
                ),
                let http = response as? HTTPURLResponse,
                (200..<400).contains(http.statusCode),
                validateImage(data)
            else {
                continue
            }

            guard let hash = perceptualHash(data) else {
                continue
            }

            let isVisualDuplicate = perceptualHashes.contains { existingHash in
                hammingDistance(
                    existingHash,
                    hash
                ) <= 6
            }

            guard !isVisualDuplicate else {
                continue
            }

            perceptualHashes.append(hash)

            let finalScore =
                rankedScore(candidate)
                + imageQualityScore(data)

            onResult(
                OnlineIconResult(
                    id: candidateURL,
                    url: candidateURL,
                    data: data,
                    score: finalScore
                )
            )
        }
    }
    
    private func looksLikeBanner(
        _ url: URL
    ) -> Bool {
        let value = url.absoluteString.lowercased()

        return [
            "banner",
            "poster",
            "hero",
            "cover",
            "social",
            "og-image"
        ]
        .contains {
            value.contains($0)
        }
    }
    
    private func validateImage(
        _ data: Data
    ) -> Bool {
        // Reject PDF
        if data.starts(with: Data("%PDF".utf8)) {
            return false
        }
        
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            ),
            let type = CGImageSourceGetType(source),
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return false
        }
        
        let supportedTypes: Set<CFString> = [
            UTType.png.identifier as CFString,
            UTType.jpeg.identifier as CFString,
            "org.webmproject.webp" as CFString
        ]
        
        guard supportedTypes.contains(type) else {
            return false
        }
        
        return width == height
    }
    
    private func sourceScore(
        _ source: IconCandidate.Source
    ) -> Int {
        switch source {
        case .manifest:
            return 1000
            
        case .appleTouchIcon:
            return 900
            
        case .microsoftTile:
            return 850
            
        case .favicon:
            return 600
            
        case .appStore:
            return 800

        case .playStore:
            return 750
            
        case .wikimedia:
            return 450
            
        case .imageSource:
            return 250

        case .openGraph:
            return 100

        case .twitterCard:
            return 50
            
        case .googleFavicon:
            return 200
            
        case .duckDuckGoFavicon:
            return 180
            
        case .fallback:
            return 100
        }
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
    
    private func rankedScore(
        _ candidate: IconCandidate
    ) -> Int {
        sourceScore(candidate.source)
        + candidate.score
        + (candidate.declaredSize ?? 0)
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
    
    private func imageQualityScore(
        _ data: Data
    ) -> Int {
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
            let width = properties[kCGImagePropertyPixelWidth] as? Int
        else {
            return 0
        }
        
        switch width {
        case 512...:
            return 300
        case 256...:
            return 200
        case 128...:
            return 100
        default:
            return 0
        }
    }
    
    private func perceptualHash(
        _ data: Data
    ) -> UInt64? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            ),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
            )
        else {
            return nil
        }
        
        let width = 8
        let height = 8
        var pixels = [UInt8](
            repeating: 0,
            count: width * height
        )
        
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        else {
            return nil
        }
        
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
        )
        
        let average = pixels.reduce(0) {
            $0 + Int($1)
        } / pixels.count
        
        var hash: UInt64 = 0
        
        for (index, pixel) in pixels.enumerated()
        where Int(pixel) >= average {
            hash |= UInt64(1) << UInt64(index)
        }
        
        return hash
    }
    
    private func hammingDistance(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> Int {
        (lhs ^ rhs).nonzeroBitCount
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
