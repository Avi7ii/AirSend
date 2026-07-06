// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AirSend-macOS",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AirSendUpdater", targets: ["AirSendUpdater"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        .target(
            name: "AirSendUpdater"
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "AirSend",
            dependencies: [
                "AirSendUpdater",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: [
                "icon.svg",
                "m3-icon-dynamic-rose-1024px.png",
                "m3-icon-dynamic-rose.svg",
            ],
            swiftSettings: [
                .define("ENABLE_SPARKLE"),
            ],
            linkerSettings: [
                 .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        ),
        .executableTarget(
            name: "AirSendUpdaterSelfTests",
            dependencies: [
                "AirSendUpdater",
            ],
            path: "Tests/AirSendUpdaterSelfTests"
        ),
    ]
)
