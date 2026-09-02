// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "native_feed_player",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "native-feed-player", targets: ["native_feed_player"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "native_feed_player",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
