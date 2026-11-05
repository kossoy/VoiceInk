// swift-tools-version:5.9
// OKLabs fork: the Scribe engine core (Foundation only) as a SwiftPM package,
// so its tests run with `swift test` without building the app, plus the
// `scribe-bench` real-voice harness. The app compiles the same ScribeCore
// sources through VoiceInk.xcodeproj; this file does not affect that build.
// OKLabsVocabulary also compiles the real app settings and correction path for
// regression tests without building the full app or copying production sources.
// OKLabsUpdater compiles the real fork adapter and its upstream compilation boundary
// without a Sparkle dependency, so accidentally including the upstream updater fails.
import PackageDescription

let package = Package(
    name: "VoiceInkOKLabs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"]),
        .executable(name: "scribe-bench", targets: ["ScribeBench"]),
    ],
    targets: [
        .target(name: "ScribeCore", path: "VoiceInk/OKLabs/ScribeCore"),
        .target(
            name: "OKLabsUpdater", path: "VoiceInk",
            sources: [
                "OKLabs/OKLabsUpdaterViewModel.swift",
                "App/Updates/UpdaterViewModel.swift",
            ],
            swiftSettings: [.define("OKLABS")]),
        .target(
            name: "OKLabsVocabulary", path: "VoiceInk",
            sources: [
                "OKLabs/OKLabsSettings.swift",
                "Features/Dictionary/Workflows/RecordingVocabulary.swift",
                "Features/Dictionary/Workflows/PhoneticVocabularyMatcher.swift",
                "Features/Dictionary/Workflows/VocabularyPhonetics.swift",
            ],
            swiftSettings: [.define("OKLABS")]),
        .target(name: "ScribeBenchKit", dependencies: ["ScribeCore"], path: ".oklabs/scribe-bench/ScribeBenchKit"),
        .executableTarget(
            name: "ScribeBench", dependencies: ["ScribeBenchKit", "ScribeCore"],
            path: ".oklabs/scribe-bench/ScribeBench"),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"], path: "Tests/ScribeCoreTests"),
        .testTarget(
            name: "OKLabsUpdaterTests", dependencies: ["OKLabsUpdater"],
            path: "Tests/OKLabsUpdaterTests"),
        .testTarget(
            name: "OKLabsVocabularyTests", dependencies: ["OKLabsVocabulary"],
            path: "Tests/OKLabsVocabularyTests"),
        .testTarget(
            name: "ScribeBenchKitTests", dependencies: ["ScribeBenchKit"], path: "Tests/ScribeBenchKitTests"),
    ]
)
