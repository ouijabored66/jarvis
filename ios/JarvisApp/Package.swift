// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "JarvisApp", targets: ["JarvisApp"])],
    targets: [.target(name: "JarvisApp", swiftSettings: [.swiftLanguageMode(.v5)])]
)
