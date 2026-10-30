import Foundation

/// Cultures with matching Microsoft ARM64 installation media.
enum WindowsCulture: String, CaseIterable {
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case dutch = "nl-NL"
    case german = "de-DE"
    case french = "fr-FR"

    var title: String {
        switch self {
        case .englishUS: return "English (United States)"
        case .englishUK: return "English (United Kingdom)"
        case .dutch: return "Nederlands (Nederland)"
        case .german: return "Deutsch (Deutschland)"
        case .french: return "Français (France)"
        }
    }

    var microsoftLanguage: String {
        switch self {
        case .englishUS: return "English"
        case .englishUK: return "English International"
        case .dutch: return "Dutch"
        case .german: return "German"
        case .french: return "French"
        }
    }

    var cacheKey: String {
        self == .englishUS ? "windows-11-arm64-english" : "windows-11-arm64-\(rawValue.lowercased())"
    }
}
