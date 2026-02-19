// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AirSend-macOS",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // No dependencies! Using native Network.framework for HTTPS
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "AirSend",
            dependencies: [
            ],
            linkerSettings: [
                 .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        ),
    ]
)
