import SwiftUI

/// sRGB tokens measured against the approved workspace screens at 1280 × 720 points.
public enum LoffoPalette {
    public static let canvas = Color(red: 0.986, green: 0.977, blue: 0.986)
    public static let surface = Color(.sRGB, red: 252 / 255, green: 251 / 255, blue: 253 / 255, opacity: 1)
    public static let comparisonSurface = Color(
        .sRGB, red: 252 / 255, green: 250 / 255, blue: 253 / 255, opacity: 1)
    public static let inspectorSurface = Color(
        .sRGB, red: 253 / 255, green: 250 / 255, blue: 252 / 255, opacity: 1)
    public static let accent = Color(red: 1.0, green: 0.38, blue: 0.06)
    public static let selection = Color(red: 0.993, green: 0.940, blue: 0.920)
    public static let text = Color(red: 0.08, green: 0.08, blue: 0.10)
    public static let secondary = Color(red: 0.49, green: 0.48, blue: 0.50)
    public static let border = Color(red: 0.91, green: 0.90, blue: 0.91)
    public static let added = Color(red: 0.0, green: 0.47, blue: 0.04)
    public static let modified = Color(red: 0.67, green: 0.45, blue: 0.18)
    public static let removed = Color(red: 0.85, green: 0.02, blue: 0.03)
    public static let addedBackground = Color(red: 0.945, green: 0.975, blue: 0.947)
    public static let removedBackground = Color(red: 0.994, green: 0.943, blue: 0.950)
}

public enum LoffoMetrics {
    public static let rail: CGFloat = 64
    public static let sidebar: CGFloat = 284
    public static let inspector: CGFloat = 290
    public static let header: CGFloat = 54
    public static let toolbar: CGFloat = 54
    public static let changesRow: CGFloat = 38
    public static let row: CGFloat = 31
    public static let line: CGFloat = 20
    public static let codeSize: CGFloat = 12
    public static let diffTrailingInset: CGFloat = 12
    public static let radius: CGFloat = 18
    public static let comparisonRadius: CGFloat = 10
    public static let cardRadius: CGFloat = 12
}
