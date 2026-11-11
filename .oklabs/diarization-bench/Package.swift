// swift-tools-version:6.2
// OKLabs fork: measures meeting speaker separation on a saved meeting, outside the app.
// Same FluidAudio revision and trait as the app (Package.resolved, project.pbxproj).
//   swift run -c release --package-path .oklabs/diarization-bench diarization-bench \
//     ~/Library/Application\ Support/com.prakashjoshipax.VoiceInk/Meetings/<id> [maxSpeakers]
// Reads the session's audio/*.wav and session.json; writes nothing into it.
import PackageDescription

let package = Package(
    name: "DiarizationBench", platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio", revision: "ee78635d23d52379117554ba72358b65a0612447",
            traits: ["Diarizer"])
    ],
    targets: [
        .executableTarget(
            name: "diarization-bench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/DiarizationBench")
    ])
