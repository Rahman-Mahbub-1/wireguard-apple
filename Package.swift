// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WireGuardKit",
    platforms: [
        .macOS(.v11),
        .iOS("15.0")
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"])
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
            dependencies: [],
            path: "Sources/WireGuardKitGo",
            exclude: [
                "goruntime-boottime-over-monotonic.diff",
                "go.mod",
                "go.sum", 
                "api-apple.go",
                "Makefile",
                ".tmp",
                ".gitignore",
                "out"
            ],
            sources: ["dummy.c"],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
                .define("SWIFT_PACKAGE")
            ],
            linkerSettings: [
                .linkedLibrary("wg-go"),
                .unsafeFlags(["-L", "Sources/WireGuardKitGo"], .when(platforms: [.iOS, .macOS]))
            ]
        )
    ]
)
