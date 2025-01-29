// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftLogFileLogHandler",
    platforms: [ .iOS(.v14), .macOS(.v10_13)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftLogFileLogHandler",
            targets: ["SwiftLogFileLogHandler"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.1"
        )
    ],
    targets: [
        .target(
            name: "SwiftLogFileLogHandler",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "SwiftLogFileLogHandlerTests",
            dependencies: ["SwiftLogFileLogHandler"]
        ),
    ]
)
