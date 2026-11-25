// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "T3Bar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "T3Bar", targets: ["T3Bar"])
    ],
    targets: [
        .executableTarget(
            name: "T3Bar",
            path: "Sources/T3Bar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
