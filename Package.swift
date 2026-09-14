// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tally",
    // 15 是为了 @Observable + Scene.defaultLaunchBehavior 这一代 API，
    // 也和 Watchdog 保持同一基线。
    platforms: [.macOS(.v15)],
    // 零第三方依赖：壳、hook、定位全靠系统框架。
    targets: [
        // app 与 hook 共用的模型和判定
        .target(
            name: "TallyKit",
            path: "Sources/TallyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Tally",
            dependencies: ["TallyKit"],
            path: "Sources/Tally",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 装进 Tally.app/Contents/MacOS/tally-hook，由 Claude Code / Codex 的 hook 调用
        .executableTarget(
            name: "TallyHook",
            dependencies: ["TallyKit"],
            path: "Sources/TallyHook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TallyTests",
            dependencies: ["Tally", "TallyKit"],
            path: "Tests/TallyTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
