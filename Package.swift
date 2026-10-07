// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fontso",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fontso", targets: ["Fontso"])
    ],
    targets: [
        .target(
            name: "FontsoCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("Vision"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "Fontso",
            dependencies: ["FontsoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("FoundationModels"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "FontsoTests",
            dependencies: ["FontsoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
