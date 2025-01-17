// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "Cache",
    platforms: [.macOS(.v11), .iOS(.v14), .watchOS(.v4)],
    products: [
        .library(
            name: "Cache",
            targets: ["Cache"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Cache",
            path: "Source",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "CacheTests",
            dependencies: ["Cache"],
            path: "Tests"),
    ],
    swiftLanguageVersions: [.v5]
)
