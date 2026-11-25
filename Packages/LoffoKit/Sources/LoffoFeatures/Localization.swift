import Foundation

enum L10n {
    static func format(_ key: String, _ count: Int) -> String { String(format: text(key), count) }
    static func format(_ key: String, _ value: String) -> String { String(format: text(key), value) }
    static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .module)
    }
}
