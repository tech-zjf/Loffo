// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoffoKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "LoffoKit",
            targets: [
                "LoffoDomain", "LoffoDocument", "LoffoDiff", "LoffoInfrastructure", "LoffoFeatures",
                "LoffoEditorUI",
            ])
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", exact: "0.23.5"),
        .package(
            url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.1"),
    ],
    targets: [
        .target(name: "LoffoDomain", exclude: ["Localization"], resources: [.process("Resources")]),
        .target(
            name: "LoffoDocument",
            dependencies: [
                "LoffoDomain", .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
            resources: [.process("SyntaxQueries")]),
        .target(name: "LoffoDiff", dependencies: ["LoffoDomain"]),
        .target(name: "LoffoInfrastructure", dependencies: ["LoffoDomain", "LoffoDocument"]),
        .target(name: "LoffoDesignSystem"),
        .target(name: "LoffoEditorUI", dependencies: ["LoffoDomain", "LoffoDesignSystem"]),
        .target(
            name: "LoffoFeatures", dependencies: ["LoffoDomain", "LoffoEditorUI", "LoffoDesignSystem"],
            exclude: ["Localization"], resources: [.process("Resources")]),
        .testTarget(
            name: "LoffoKitTests",
            dependencies: [
                "LoffoDomain", "LoffoDocument", "LoffoDiff", "LoffoInfrastructure", "LoffoFeatures",
                "LoffoEditorUI",
            ]),
    ]
)
