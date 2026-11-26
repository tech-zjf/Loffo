import Foundation
import LoffoDomain
import SwiftUI

/// Semantic editor colors. VS Code TextMate theme scopes are mapped into these stable categories.
public struct EditorSyntaxTheme: Sendable, Equatable {
    private var colors: [SyntaxKind: String]
    private var foregroundHex: String

    public static let standard = EditorSyntaxTheme(colors: [
        .keyword: "AD1AF2", .string: "337B5C", .comment: "0D6E21", .number: "E07A20",
        .type: "000950", .importPath: "D61F27", .functionCall: "850023", .constructor: "006270",
        .parameter: "4470F6",
    ])

    public init(colors: [SyntaxKind: String], foreground: String = "000950") {
        self.colors = colors
        foregroundHex = foreground
    }

    public func color(for kind: SyntaxKind) -> Color {
        Color(hex: hexColor(for: kind))
    }

    public func hexColor(for kind: SyntaxKind) -> String {
        colors[kind] ?? Self.standard.colors[kind] ?? "000950"
    }

    public var hexForeground: String { foregroundHex }
    public var foreground: Color { Color(hex: foregroundHex) }

    /// Imports the TextMate `tokenColors` subset used by VS Code theme JSON files.
    /// Workbench colors and semantic token rules are intentionally ignored.
    public init(vscodeJSON data: Data) throws {
        guard data.count <= 2 * 1_024 * 1_024,
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokenColors = root["tokenColors"] as? [[String: Any]]
        else { throw ThemeImportError.invalidTheme }

        var result = Self.standard.colors
        var defaultForeground = "000950"
        if let settings = root["settings"] as? [String: Any],
            let value = settings["foreground"] as? String, Self.isHexColor(value)
        {
            defaultForeground = value
        }
        for rule in tokenColors {
            guard let settings = rule["settings"] as? [String: Any],
                let foreground = settings["foreground"] as? String,
                Self.isHexColor(foreground)
            else { continue }
            let scopes: [String]
            if let values = rule["scope"] as? [String] {
                scopes = values
            } else if let value = rule["scope"] as? String {
                scopes = value.split(separator: ",").map(String.init)
            } else {
                continue
            }
            for scope in scopes.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                if scope.contains("comment") { result[.comment] = foreground }
                if scope.contains("string") { result[.string] = foreground }
                if scope.contains("keyword") || scope.contains("storage") { result[.keyword] = foreground }
                if scope.contains("numeric") || scope.contains("number") { result[.number] = foreground }
                if scope.contains("entity.name.type") || scope.contains("support.type") {
                    result[.type] = foreground
                    result[.constructor] = foreground
                }
                if scope.contains("entity.name.function") || scope.contains("support.function") {
                    result[.functionCall] = foreground
                }
                if scope.contains("variable.parameter") { result[.parameter] = foreground }
            }
        }
        guard !tokenColors.isEmpty else { throw ThemeImportError.invalidTheme }
        colors = result
        foregroundHex = defaultForeground
    }

    private static func isHexColor(_ value: String) -> Bool {
        let digits = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
        return (digits.count == 6 || digits.count == 8) && digits.allSatisfy(\.isHexDigit)
    }
}

public enum ThemeImportError: Error {
    case invalidTheme
}

extension Color {
    fileprivate init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 8 { value = String(value.prefix(6)) }
        let number = UInt64(value, radix: 16) ?? 0x10111A
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            opacity: 1
        )
    }
}
