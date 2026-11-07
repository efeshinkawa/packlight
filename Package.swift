// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Packlight",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Packlight",
            path: "Sources/Packlight",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
