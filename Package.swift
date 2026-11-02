// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentBoundaryKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentBoundaryKit", targets: ["AgentBoundaryKit"]),
    ],
    targets: [
        .target(name: "AgentBoundaryKit"),
        .testTarget(name: "AgentBoundaryKitTests", dependencies: ["AgentBoundaryKit"]),
    ]
)
