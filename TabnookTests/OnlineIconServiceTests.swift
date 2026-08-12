//
//  OnlineIconServiceTests.swift
//  TabnookTests
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation
import Testing

@testable import Tabnook

struct OnlineIconServiceTests {
    @Test
    func returnsDownloadedCandidates() async throws {
        let session = MockURLSession(
            responses: [
                URL(string: "https://example.com")!: (
                    Data(
                        """
                        <link rel="apple-touch-icon" href="/icon.png">
                        """.utf8
                    ),
                    HTTPURLResponse(
                        url: URL(string: "https://example.com")!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                ),
                URL(string: "https://example.com/icon.png")!: (
                    Data([1, 2, 3]),
                    HTTPURLResponse(
                        url: URL(string: "https://example.com/icon.png")!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            ]
        )

        let service = OnlineIconService(session: session)

        let result = try await service.search(
            websiteURL: URL(string: "https://example.com")!
        )

        #expect(result.count == 1)
        #expect(result[0].url.absoluteString == "https://example.com/icon.png")
    }
}

private struct MockURLSession: URLSessioning {
    let responses: [URL: (Data, URLResponse)]

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = responses[url]
        else {
            throw URLError(.badURL)
        }

        return response
    }
}
