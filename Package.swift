// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "swift-openrpc-generator",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "OpenRPCGeneratorKit", targets: ["OpenRPCGeneratorKit"]),
        .executable(name: "swift-openrpc-generator", targets: ["swift-openrpc-generator"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "OpenRPCGeneratorKit"),
        .executableTarget(
            name: "swift-openrpc-generator",
            dependencies: [
                "OpenRPCGeneratorKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "OpenRPCGeneratorKitTests",
            dependencies: ["OpenRPCGeneratorKit"],
            exclude: ["Golden"]
        ),
    ]
)

for target in package.targets {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InternalImportsByDefault"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .strictMemorySafety(),
        ]
}
