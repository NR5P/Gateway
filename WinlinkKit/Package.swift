// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WinlinkKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WinlinkKit", targets: ["WinlinkKit"]),
        .executable(name: "test-gateway", targets: ["TestGateway"]),
    ],
    targets: [
        .target(
            name: "WinlinkKit",
            // LZHUF walks a binary tree per input byte; keep Debug builds usable.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        // A stand-in RMS for testing: answers VARA calls and swaps messages (macOS).
        .executableTarget(name: "TestGateway", dependencies: ["WinlinkKit"]),
        .testTarget(
            name: "WinlinkKitTests",
            dependencies: ["WinlinkKit"],
            resources: [.copy("Resources")]
        ),
    ]
)
