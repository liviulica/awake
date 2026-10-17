// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Insomnia",
    platforms: [
        .macOS(.v26),
    ],
    // The module and target keep Insomnia's name so upstream fixes still
    // merge; the built binary is Ember. EmberHelper is the privileged helper
    // build-app.sh puts beside it (Contents/MacOS).
    products: [
        .executable(name: "Ember", targets: ["Insomnia"]),
        .executable(name: "EmberHelper", targets: ["EmberHelper"]),
    ],
    dependencies: [
        // Exact: the release script signs the framework's nested code by
        // path, and the appcast tools come from this same artifact.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Insomnia",
            dependencies: [
                "EmberHelperKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Insomnia",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            // Sparkle.framework sits in Contents/Frameworks (build-app.sh).
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // What the app and the helper share: the XPC protocol, the names and
        // code requirements, the restore rule and the helper's commands.
        .target(
            name: "EmberHelperKit",
            path: "Sources/EmberHelperKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "EmberHelper",
            dependencies: ["EmberHelperKit"],
            path: "Sources/EmberHelper",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Test-only C target. Its constructor points EMBER_HOME at a temp
        // directory when the test bundle loads, before any test can log.
        .target(
            name: "InsomniaTestHome",
            path: "Tests/InsomniaTestHome"
        ),
        .testTarget(
            name: "InsomniaTests",
            dependencies: ["Insomnia", "EmberHelperKit", "InsomniaTestHome"],
            path: "Tests/InsomniaTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
