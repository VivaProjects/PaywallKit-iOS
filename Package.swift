// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaywallKit",
    platforms: [.iOS(.v16)],
    products: [.library(name: "PaywallKit", targets: ["PaywallKit"])],
    targets: [.target(name: "PaywallKit", resources: [.process("Resources")])]
)
