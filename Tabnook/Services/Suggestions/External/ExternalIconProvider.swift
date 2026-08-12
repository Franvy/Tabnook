//
//  ExternalIconProvider.swift
//  Tabnook
//
//  Created by Laurens Karpf on 12.08.2026.
//

import Foundation

protocol ExternalIconProvider: Sendable {
    func candidates(
        for websiteURL: URL
    ) async -> [IconCandidate]
}
