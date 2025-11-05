// swift-tools-version:5.3

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
                "out",
                "wg-go.pc"
            ],
            sources: ["dummy.c"],
            resources: [
                .copy("libwg-go.a")
            ],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
                .define("SWIFT_PACKAGE")
            ]
            // Remove all linkerSettings that cause conflicts
        )
    ]
)
