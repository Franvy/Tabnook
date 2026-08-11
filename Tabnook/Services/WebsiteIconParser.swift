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

        let pattern = #"<link\s+[^>]*>"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(
            html.startIndex..<html.endIndex,
            in: html
        )

        let matches = regex.matches(
            in: html,
            options: [],
            range: range
        )

        for match in matches {
            guard let matchRange = Range(match.range, in: html) else {
                continue
            }

            let tag = String(html[matchRange])

            let rel = attribute(
                named: "rel",
                in: tag
            )?.lowercased() ?? ""

            guard
                rel.contains("icon") ||
                rel.contains("apple-touch-icon")
            else {
                continue
            }

            guard let href = attribute(
                named: "href",
                in: tag
            ),
            let url = URL(
                string: href,
                relativeTo: baseURL
            )?.absoluteURL,
            let scheme = url.scheme,
            scheme == "https" || scheme == "http"
            else {
                continue
            }

            let source: IconCandidate.Source
            let score: Int

            if rel.contains("apple-touch-icon") {
                source = .appleTouchIcon
                score = 300
            } else {
                source = .favicon
                score = 100
            }

            results.append(
                IconCandidate(
                    url: url,
                    source: source,
                    score: score
                )
            )
        }

        return deduplicated(results)
    }

    private func attribute(
        named name: String,
        in tag: String
    ) -> String? {
        let pattern =
            #"\#(name)\s*=\s*["']([^"']+)["']"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
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
