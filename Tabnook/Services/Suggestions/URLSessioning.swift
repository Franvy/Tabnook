//
//  URLSessioning.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

protocol URLSessioning: Sendable {
    func data(
        from url: URL
    ) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessioning {}
