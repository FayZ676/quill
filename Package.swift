// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Quill",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Quill",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Quill",
            // Sparkle.framework is copied into Contents/Frameworks by build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
