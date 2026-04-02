// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCHP",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CCHP",
            path: "Sources/CCHP"
        )
    ]
)
