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
        .parameter: "4470F6", .property: "6F42C1", .constant: "B85C00",
        .heading: "34304A", .markup: "8B6B40", .link: "176B87", .code: "4D5967",
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

    /// Imports syntax colors from VS Code/TextMate or Zed theme JSON without changing Loffo's UI.
    public init(importing data: Data) throws {
        guard data.count <= 2 * 1_024 * 1_024,
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ThemeImportError.invalidTheme }

        if let tokenColors = root["tokenColors"] as? [[String: Any]] {
            self = try Self.importingVSCode(
                tokenColors: tokenColors, settings: root["settings"] as? [String: Any])
            return
        }

        let themeObject: [String: Any]
        if let themes = root["themes"] as? [[String: Any]], let first = themes.first {
            themeObject = first
        } else {
            themeObject = root
        }
        guard let style = themeObject["style"] as? [String: Any],
            let syntax = style["syntax"] as? [String: Any]
        else { throw ThemeImportError.invalidTheme }
        var result = Self.standard.colors
        for (name, rawStyle) in syntax {
            let value = rawStyle as? [String: Any]
            let color = value?["color"] as? String ?? rawStyle as? String
            guard let color, Self.isHexColor(color) else { continue }
            Self.apply(color: color, scope: name.lowercased(), to: &result)
        }
        guard !syntax.isEmpty else { throw ThemeImportError.invalidTheme }
        let foreground: String
        if let value = style["foreground"] as? String, Self.isHexColor(value) {
            foreground = value
        } else {
            foreground = Self.standard.hexForeground
        }
        self.init(colors: result, foreground: foreground)
    }

    private static func importingVSCode(
        tokenColors: [[String: Any]], settings: [String: Any]?
    ) throws -> EditorSyntaxTheme {
        var result = Self.standard.colors
        let defaultForeground: String
        if let value = settings?["foreground"] as? String, Self.isHexColor(value) {
            defaultForeground = value
        } else {
            defaultForeground = Self.standard.hexForeground
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
                Self.apply(color: foreground, scope: scope, to: &result)
            }
        }
        guard !tokenColors.isEmpty else { throw ThemeImportError.invalidTheme }
        return EditorSyntaxTheme(colors: result, foreground: defaultForeground)
    }

    private static func apply(color: String, scope: String, to colors: inout [SyntaxKind: String]) {
        switch scope {
        case "property":
            colors[.property] = color
            return
        case "constant":
            colors[.constant] = color
            return
        case "heading":
            colors[.heading] = color
            return
        case "markup":
            colors[.markup] = color
            return
        case "link":
            colors[.link] = color
            return
        case "code":
            colors[.code] = color
            return
        case "function":
            colors[.functionCall] = color
            return
        case "type":
            colors[.type] = color
            return
        case "parameter":
            colors[.parameter] = color
            return
        case "number":
            colors[.number] = color
            return
        case "string":
            colors[.string] = color
            return
        case "keyword":
            colors[.keyword] = color
            return
        case "comment":
            colors[.comment] = color
            return
        default: break
        }
        if scope.contains("comment") { colors[.comment] = color }
        if scope.contains("string") { colors[.string] = color }
        if scope.contains("keyword") || scope.contains("storage") { colors[.keyword] = color }
        if scope.contains("numeric") || scope.contains("number") { colors[.number] = color }
        if scope.contains("entity.name.type") || scope.contains("support.type") {
            colors[.type] = color
            colors[.constructor] = color
        }
        if scope.contains("entity.name.function") || scope.contains("support.function") {
            colors[.functionCall] = color
        }
        if scope.contains("variable.parameter") { colors[.parameter] = color }
        if scope.contains("property") || scope.split(separator: ".").contains("key") {
            colors[.property] = color
        }
        if scope.contains("constant") || scope.contains("boolean") { colors[.constant] = color }
        if scope.contains("heading") || scope.contains("text.title") { colors[.heading] = color }
        if scope.contains("punctuation") || scope.contains("markup") { colors[.markup] = color }
        if scope.contains("link") || scope.contains("uri") || scope.contains("reference") {
            colors[.link] = color
        }
        if scope.contains("code") || scope.contains("literal") { colors[.code] = color }
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
