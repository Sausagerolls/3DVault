// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VaultKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "VaultKit", targets: ["VaultKit"])],
    targets: [
        .target(name: "VaultKit"),
        .testTarget(name: "VaultKitTests", dependencies: ["VaultKit"], resources: [.copy("Fixtures")]),
    ]
)
