//
//  WebsiteIconParserTests.swift
//  TabnookTests
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation
import Testing

@testable import Tabnook

struct WebsiteIconParserTests {
    private let parser = WebsiteIconParser()

    @Test
    func parsesAppleTouchIcon() throws {
        let html = """
        <html>
        <head>
        <link rel="apple-touch-icon" href="/apple-touch-icon.png">
        </head>
        </html>
        """

        let result = parser.candidates(
            from: html,
            baseURL: URL(string: "https://example.com/path")!
        )

        #expect(result.count == 1)
        #expect(result[0].url.absoluteString == "https://example.com/apple-touch-icon.png")
        #expect(result[0].source == .appleTouchIcon)
    }

    @Test
    func parsesRelativeFavicon() throws {
        let html = """
        <link rel="icon" href="icons/favicon.png">
        """

        let result = parser.candidates(
            from: html,
            baseURL: URL(string: "https://example.com/account/home")!
        )

        #expect(result.count == 1)
        #expect(
            result[0].url.absoluteString ==
            "https://example.com/account/icons/favicon.png"
        )
    }

    @Test
    func ignoresUnsupportedSchemes() {
        let html = """
        <link rel="icon" href="file:///tmp/icon.png">
        """

        let result = parser.candidates(
            from: html,
            baseURL: URL(string: "https://example.com")!
        )

        #expect(result.isEmpty)
    }

    @Test
    func prefersAppleTouchIconOverNormalFavicon() {
        let html = """
        <link rel="icon" href="/favicon.ico">
        <link rel="apple-touch-icon" href="/apple-touch-icon.png">
        """

        let result = parser.candidates(
            from: html,
            baseURL: URL(string: "https://example.com")!
        )

        #expect(result[0].source == .appleTouchIcon)
    }

    @Test
    func removesDuplicateCandidates() {
        let html = """
        <link rel="icon" href="/favicon.ico">
        <link rel="shortcut icon" href="/favicon.ico">
        """

        let result = parser.candidates(
            from: html,
            baseURL: URL(string: "https://example.com")!
        )

        #expect(result.count == 1)
    }
    
    @Test
    func parsesShortcutIcon() {
        let html = """
        <link rel="shortcut icon" href="/favicon.ico">
        """

        let result = parser.candidates(
            from: html,
            baseURL: URL(string: "https://example.com")!
        )

        #expect(result.count == 1)
        #expect(result[0].url.absoluteString == "https://example.com/favicon.ico")
        #expect(result[0].source == .favicon)
    }
}
