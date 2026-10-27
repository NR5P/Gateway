// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WinlinkKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WinlinkKit", targets: ["WinlinkKit"]),
    ],
    targets: [
        .target(
            name: "WinlinkKit",
            // LZHUF walks a binary tree per input byte; keep Debug builds usable.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "WinlinkKitTests",
            dependencies: ["WinlinkKit"],
            resources: [.copy("Resources")]
        ),
    ]
)
