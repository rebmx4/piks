// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiksCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "PiksCore", targets: ["PiksCore"])],
    targets: [
        .target(name: "PiksCore"),
        .testTarget(name: "PiksCoreTests", dependencies: ["PiksCore"])
    ]
)
