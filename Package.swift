// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Brasseur",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Brasseur", path: "Sources/Brasseur")
    ],
    swiftLanguageModes: [.v5]
)
