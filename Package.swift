// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "WireGuardKit",
    platforms: [
        .macOS(.v11),
        .iOS("15.0")
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"]),
        .library(name: "WireGuardKitGo", targets: ["WireGuardKitGo"])  // ✅ Add this product
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WireGuardKit",
            dependencies: ["WireGuardKitGo", "WireGuardKitC"],
            path: "Sources/WireGuardKit"
        ),
        .target(
            name: "WireGuardKitC",
            dependencies: [],
            path: "Sources/WireGuardKitC",
            publicHeadersPath: "."
        ),
        .target(
            name: "WireGuardKitGo",
            dependencies: ["WireGuardKitGoBinary"],
            path: "Sources/WireGuardKitGo",
            exclude: [
                "goruntime-boottime-over-monotonic.diff",
                "go.mod",
                "go.sum", 
                "api-apple.go",
                "Makefile",
                ".gitignore",
                "wg-go.pc",
                "libwg-go.a"
            ],
            sources: ["dummy.c"],
            publicHeadersPath: "."
        ),
        .binaryTarget(
            name: "WireGuardKitGoBinary",
            path: "Sources/WireGuardKitGo/libwg-go.xcframework"
        )
    ]
)
