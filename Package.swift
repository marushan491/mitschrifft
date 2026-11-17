// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mitschrift",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "mitschrift",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/mitschrift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "MitschriftTests", dependencies: ["mitschrift"], path: "Tests",
                    exclude: ["run_checks.sh", "test_ask_codex.py", "test_live_mcp.py", "test_pandaos_chat.mjs"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
