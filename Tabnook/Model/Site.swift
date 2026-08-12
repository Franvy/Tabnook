import Foundation
import CryptoKit

enum IconStyle: Int, CaseIterable, Identifiable, Sendable {
    case glassSmall = 0
    case transparentBig = 1
    case glassBig = 3

    var id: Int { rawValue }

    var debugName: String {
        switch self {
        case .glassSmall: return "glassSmall"
        case .transparentBig: return "transparentBig"
        case .glassBig: return "glassBig"
        }
    }

    var localizedLabel: LocalizedStringResource {
        switch self {
        case .glassSmall:     return "Glass · Small"
        case .transparentBig: return "Transparent · Large"
        case .glassBig:       return "Glass · Large"
        }
    }

    static func interpreted(from rawValue: Int?) -> IconStyle? {
        switch rawValue {
        case 2:
            return .glassSmall
        case let value?:
            return IconStyle(rawValue: value)
        case nil:
            return nil
        }
    }
}

struct Site: Identifiable, Hashable, Sendable {
    let host: String
    let md5: String
    let iconURL: URL
    var rawStyleValue: Int?

    var interpretedStyle: IconStyle? {
        IconStyle.interpreted(from: rawStyleValue)
    }

    var style: IconStyle {
        get { interpretedStyle ?? .glassSmall }
        set { rawStyleValue = newValue.rawValue }
    }

    var rawStyleValueText: String {
        rawStyleValue.map(String.init) ?? "missing"
    }

    var styleMeaningText: String {
        if let interpretedStyle {
            return "\(interpretedStyle.debugName) / \(interpretedStyle.localizedLabel)"
        }

        if rawStyleValue != nil {
            return String(localized: "unknown")
        }

        return String(localized: "no cache_settings row")
    }

    var usesGlassBackground: Bool {
        interpretedStyle == .glassSmall || interpretedStyle == .glassBig
    }

    var usesGlassSmallInset: Bool {
        interpretedStyle == .glassSmall
    }

    var needsStyleHint: Bool {
        rawStyleValue == nil || interpretedStyle == nil
    }

    var id: String { host }

    var domainName: String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return String(parts[parts.count - 2]).capitalized
    }

    init(host: String, rawStyleValue: Int?, paths: SafariPaths) {
        self.host = host
        self.rawStyleValue = rawStyleValue
        let digest = Insecure.MD5.hash(data: Data(host.utf8))
        self.md5 = digest.map { String(format: "%02hhX", $0) }.joined()
        self.iconURL = paths.iconURL(forMD5: self.md5)
    }

    init(host: String, style: IconStyle, paths: SafariPaths) {
        self.init(host: host, rawStyleValue: style.rawValue, paths: paths)
    }
}
