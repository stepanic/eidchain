// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PACEKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PACEKit", targets: ["PACEKit"])],
    dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0")],
    targets: [
        .target(name: "PACEKit", dependencies: ["BigInt"]),
        .testTarget(name: "PACEKitTests", dependencies: ["PACEKit"]),
    ]
)
