// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExViewerCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ExViewerCore", targets: ["ExViewerCore"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")],
    targets: [
        .target(name: "ExViewerCore", dependencies: ["SwiftSoup"]),
        .testTarget(name: "ExViewerCoreTests", dependencies: ["ExViewerCore"])
    ]
)
