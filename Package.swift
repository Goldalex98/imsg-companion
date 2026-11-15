// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "imsg-companion",
  platforms: [.macOS(.v14)],
  dependencies: [
    // Pinned to an exact release; Dependabot proposes bumps (docs/specs design §5.6).
    .package(url: "https://github.com/openclaw/imsg.git", exact: "0.21.0"),
  ],
  targets: [
    .target(name: "CompanionCore", dependencies: [.product(name: "IMsgCore", package: "imsg")]),
    .executableTarget(name: "imsg-companion", dependencies: ["CompanionCore"]),
    .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore", .product(name: "IMsgCore", package: "imsg")]),
  ]
)
