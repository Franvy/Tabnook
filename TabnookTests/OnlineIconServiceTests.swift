//
//  OnlineIconServiceTests.swift
//  TabnookTests
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation
import AppKit
import Testing

@testable import Tabnook

struct OnlineIconServiceTests {
    @Test
    func returnsDownloadedCandidates() async throws {
        let websiteURL = URL(
            string: "https://example.com"
        )!

        let iconURL = URL(
            string: "https://example.com/icon.png"
        )!

        let session = MockURLSession(
            responses: [
                websiteURL: (
                    Data(
                        """
                        <link rel="apple-touch-icon" href="/icon.png">
                        """.utf8
                    ),
                    HTTPURLResponse(
                        url: websiteURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                ),
                iconURL: (
                    try makeTestPNG(),
                    HTTPURLResponse(
                        url: iconURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            ]
        )

        let service = OnlineIconService(
            session: session
        )

        var results: [OnlineIconResult] = []

        for try await result in service.stream(
            websiteURL: websiteURL
        ) {
            results.append(result)
        }

        #expect(results.count == 1)
        #expect(results[0].url == iconURL)
    }
}

private func makeTestPNG() throws -> Data {
    let size = NSSize(
        width: 64,
        height: 64
    )

    let image = NSImage(
        size: size
    )

    image.lockFocus()

    NSColor.black.setFill()

    NSRect(
        origin: .zero,
        size: size
    )
    .fill()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(
            data: tiff
          ),
          let png = bitmap.representation(
            using: .png,
            properties: [:]
          )
    else {
        throw CocoaError(
            .fileWriteUnknown
        )
    }

    return png
}

private struct MockURLSession: URLSessioning {
    let responses: [URL: (Data, URLResponse)]

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        guard
            let url = request.url,
            let response = responses[url]
        else {
            throw URLError(.badURL)
        }

        return response
    }
}
