// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumenApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LumenApp", targets: ["LumenApp"])],
    targets: [.target(name: "LumenApp", swiftSettings: [.swiftLanguageMode(.v5)])]
)
