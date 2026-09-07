// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "Transcriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Transcriber",
            linkerSettings: [
                // Embed Info.plist into the bare executable so that `swift run` / Xcode-run
                // already carries the bundle identifier and privacy usage strings.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
    ]
)
