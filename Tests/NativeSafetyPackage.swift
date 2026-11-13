// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "Safety", platforms: [.macOS(.v12)], targets: [
    .target(name: "Safety"),
    .testTarget(name: "SafetyTests", dependencies: ["Safety"])
])
