// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexTouchPet",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexTouchPet", targets: ["CodexTouchPet"])
    ],
    targets: [
        .target(
            name: "TouchBarPrivate",
            path: "Sources/TouchBarPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "CodexTouchPet",
            dependencies: ["TouchBarPrivate"],
            path: "Sources/CodexTouchPet",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "CodexTouchPetTests",
            dependencies: ["CodexTouchPet"],
            path: "Tests/CodexTouchPetTests"
        )
    ]
)
