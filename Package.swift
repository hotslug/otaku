// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Otaku",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "Otaku", swiftSettings: [.swiftLanguageMode(.v5)])]
)
