//
//  WebsiteIconParser.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

struct WebsiteIconParser: Sendable {
    func candidates(
        from html: String,
        baseURL: URL
    ) -> [IconCandidate] {
        var results: [IconCandidate] = []

        results += parseLinkTags(
            html,
            baseURL: baseURL
        )

        results += parseMetaTags(
            html,
            baseURL: baseURL
        )

        results += fallbackCandidates(
            baseURL: baseURL
        )

        return deduplicated(results)
    }

    func manifestURL(
        from html: String,
        baseURL: URL
    ) -> URL? {
        parseLinkTags(
            html,
            baseURL: baseURL
        )
        .first(where: { $0.source == .manifest })?
        .url
    }

    private func parseLinkTags(
        _ html: String,
        baseURL: URL
    ) -> [IconCandidate] {
        var results: [IconCandidate] = []

        for tag in tags(
            matching: #"<link\s+[^>]*>"#,
            in: html
        ) {
            let rel = attribute(
                "rel",
                in: tag
            )?.lowercased() ?? ""

            guard let href = attribute(
                "href",
                in: tag
            ),
            let url = resolvedURL(
                href,
                baseURL: baseURL
            )
            else {
                continue
            }

            if rel.contains("manifest") {
                results.append(
                    IconCandidate(
                        url: url,
                        source: .manifest,
                        score: 250
                    )
                )
            } else if rel.contains("apple-touch-icon") {
                results.append(
                    IconCandidate(
                        url: url,
                        source: .appleTouchIcon,
                        score: 400,
                        declaredSize: size(
                            from: attribute("sizes", in: tag)
                        )
                    )
                )
            } else if rel.contains("icon") {
                results.append(
                    IconCandidate(
                        url: url,
                        source: .favicon,
                        score: 200,
                        declaredSize: size(
                            from: attribute("sizes", in: tag)
                        )
                    )
                )
            }
        }

        return results
    }

    private func parseMetaTags(
        _ html: String,
        baseURL: URL
    ) -> [IconCandidate] {
        var results: [IconCandidate] = []

        for tag in tags(
            matching: #"<meta\s+[^>]*>"#,
            in: html
        ) {
            let property = attribute(
                "property",
                in: tag
            )?.lowercased()

            let name = attribute(
                "name",
                in: tag
            )?.lowercased()

            guard let content = attribute(
                "content",
                in: tag
            ),
            let url = resolvedURL(
                content,
                baseURL: baseURL
            )
            else {
                continue
            }

            if property == "og:image" {
                results.append(
                    IconCandidate(
                        url: url,
                        source: .openGraph,
                        score: 50
                    )
                )
            }

            if name == "twitter:image" {
                results.append(
                    IconCandidate(
                        url: url,
                        source: .twitterCard,
                        score: 40
                    )
                )
            }
        }

        return results
    }

    private func fallbackCandidates(
        baseURL: URL
    ) -> [IconCandidate] {
        [
            "apple-touch-icon.png",
            "apple-touch-icon-precomposed.png",
            "favicon.ico"
        ]
        .compactMap {
            resolvedURL(
                $0,
                baseURL: baseURL
            )
        }
        .map {
            IconCandidate(
                url: $0,
                source: .fallback,
                score: 100
            )
        }
    }

    private func tags(
        matching pattern: String,
        in html: String
    ) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )
        else {
            return []
        }

        let range = NSRange(
            html.startIndex..<html.endIndex,
            in: html
        )

        return regex.matches(
            in: html,
            options: [],
            range: range
        )
        .compactMap {
            guard let range = Range($0.range, in: html) else {
                return nil
            }
            return String(html[range])
        }
    }

    private func attribute(
        _ name: String,
        in tag: String
    ) -> String? {
        let pattern =
            #"\#(name)\s*=\s*["']([^"']+)["']"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )
        else {
            return nil
        }

        let range = NSRange(
            tag.startIndex..<tag.endIndex,
            in: tag
        )

        guard let match = regex.firstMatch(
            in: tag,
            options: [],
            range: range
        ),
        let valueRange = Range(
            match.range(at: 1),
            in: tag
        )
        else {
            return nil
        }

        return String(tag[valueRange])
    }

    private func resolvedURL(
        _ string: String,
        baseURL: URL
    ) -> URL? {
        guard let url = URL(
            string: string,
            relativeTo: baseURL
        )?.absoluteURL,
        let scheme = url.scheme,
        scheme == "https" || scheme == "http"
        else {
            return nil
        }

        return url
    }

    private func size(
        from value: String?
    ) -> Int? {
        guard let value else {
            return nil
        }

        return Int(
            value.split(separator: "x").first ?? ""
        )
    }

    private func deduplicated(
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
}
