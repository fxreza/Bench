// swift-tools-version: 6.2
import PackageDescription

// Bench is a pure SwiftPM package (this Mac has only the Command Line Tools,
// no Xcode). `scripts/build-app.sh` wraps the built executable into
// build.noindex/Bench.app, signs it, and installs it into /Applications.
//
// Language mode is Swift 5 everywhere: Shot and Klip were written for
// `swiftc -default-isolation MainActor` without strict concurrency, and Lingo
// (Transi) for plain Swift 5. Keeping those settings per target lets the
// ported code compile unchanged; BenchCore is written with explicit
// isolation so it is usable from both styles.
let mainActorDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self), .swiftLanguageMode(.v5)]
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Lingo's selected-text capture (Accessibility -> menu copy ->
        // AppleScript -> simulated ⌘C), the same dependency Transi uses.
        .package(url: "https://github.com/tisfeng/SelectedTextKit", branch: "main"),
    ],
    targets: [
        // Shared plumbing: feature protocol, hotkeys, shortcut store,
        // permissions, defaults, appearance.
        .target(name: "BenchCore", swiftSettings: swift5),

        // Dependency-free test framework (no XCTest on this Mac).
        .target(name: "BenchTestKit", swiftSettings: swift5),

        // Feature modules. Each exposes exactly one public type, its
        // `BenchFeature`, and keeps everything else internal so nothing
        // collides across modules.
        .target(name: "Shot", dependencies: ["BenchCore"], exclude: ["ATTRIBUTION.md"], resources: [.process("Resources")], swiftSettings: mainActorDefault),
        .target(name: "Klip", dependencies: ["BenchCore"], exclude: ["ATTRIBUTION.md"], resources: [.process("Resources")], swiftSettings: mainActorDefault),
        .target(name: "Lingo", dependencies: ["BenchCore", "SelectedTextKit"], exclude: ["ATTRIBUTION.md"], resources: [.process("Resources")], swiftSettings: swift5),
        .target(name: "Snap", dependencies: ["BenchCore"], resources: [.process("Resources")], swiftSettings: mainActorDefault),
        // Tap loads MultitouchSupport.framework with dlopen at runtime, so it
        // links nothing private and ships no resources.
        .target(name: "Tap", dependencies: ["BenchCore"], swiftSettings: mainActorDefault),
        // Piko ships the mediaremote-adapter perl script and framework as
        // verbatim resources, hence `.copy`; reach them through
        // `Bundle.module.url(forResource:withExtension:subdirectory:)`.
        .target(
            name: "Piko",
            dependencies: ["BenchCore"],
            exclude: ["ATTRIBUTION.md"],
            resources: [.copy("Resources")],
            swiftSettings: swift5,
            linkerSettings: [
                .linkedFramework("CoreAudio"), .linkedFramework("IOKit"), .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"), .linkedFramework("ScreenCaptureKit"),
            ]),

        // The app.
        .executableTarget(
            name: "Bench",
            dependencies: ["BenchCore", "Shot", "Klip", "Lingo", "Snap", "Piko", "Tap"],
            resources: [.process("Resources")],
            swiftSettings: mainActorDefault),

        // Test runners: one executable per module, run by scripts/run_tests.sh.
        // Debug builds carry -enable-testing, so `@testable import` works.
        .executableTarget(name: "BenchCoreTests", dependencies: ["BenchCore", "BenchTestKit"], swiftSettings: mainActorDefault),
        .executableTarget(name: "ShotTests", dependencies: ["Shot", "BenchTestKit"], swiftSettings: mainActorDefault),
        .executableTarget(name: "KlipTests", dependencies: ["Klip", "BenchTestKit"], swiftSettings: mainActorDefault),
        .executableTarget(name: "LingoTests", dependencies: ["Lingo", "BenchTestKit"], swiftSettings: swift5),
        .executableTarget(name: "SnapTests", dependencies: ["Snap", "BenchTestKit"], swiftSettings: mainActorDefault),
        .executableTarget(name: "TapTests", dependencies: ["Tap", "BenchTestKit"], swiftSettings: mainActorDefault),
        .executableTarget(name: "PikoTests", dependencies: ["Piko", "BenchTestKit"], swiftSettings: mainActorDefault),
    ]
)
