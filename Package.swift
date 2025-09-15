// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SyncReconcilerKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SyncReconcilerKit",
            targets: ["SyncReconcilerKit"]
        ),
    ],
    targets: [
        .target(
            name: "SyncReconcilerKit"
        ),
        .testTarget(
            name: "SyncReconcilerKitTests",
            dependencies: ["SyncReconcilerKit"]
        ),
    ]
)
