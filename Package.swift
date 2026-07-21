// swift-tools-version: 6.2
import PackageDescription

// MLXVoiceKit — native, in-process Qwen3-TTS text-to-speech on Apple Silicon
// via mlx-audio-swift, with Hugging Face model download, a hardware-aware
// memory budget, custom voice-profile conditioning, and a real-time PCM
// streaming player.
//
//   MLXVoiceCore          session-agnostic engine (provider, PCM player, ...)
//   MLXVoiceOrchestration ReadingSession-based state machine on top of the core
//
// Build note: MLX's Metal shaders require an Xcode toolchain
// (`xcodebuild -downloadComponent MetalToolchain`). A bare `swift run`
// executable builds but cannot load MLX's default Metal library. Native
// generation needs an Apple-silicon Mac with >= 16 GB unified memory.
let package = Package(
    name: "MLXVoiceKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MLXVoiceCore", targets: ["MLXVoiceCore"]),
        .library(name: "MLXVoiceOrchestration", targets: ["MLXVoiceOrchestration"]),
    ],
    dependencies: [
        .package(url: "https://github.com/fmcgoohan/SwiftSpeechSuite.git", from: "0.2.0"),
        // v0.1.3 == commit d302a5c (the reproducible benchmark revision). Pinned
        // by exact version, not revision, so this package stays version-stable
        // and can be consumed by tag from downstream SemVer packages.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "MLXVoiceCore",
            dependencies: [
                .product(name: "SwiftSpeechKit", package: "SwiftSpeechSuite"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
        .target(
            name: "MLXVoiceOrchestration",
            dependencies: [
                "MLXVoiceCore",
                .product(name: "SwiftLogKit", package: "SwiftSpeechSuite"),
                .product(name: "SwiftSpeechKit", package: "SwiftSpeechSuite"),
                .product(name: "SwiftReadingSession", package: "SwiftSpeechSuite"),
            ]
        ),
        .testTarget(name: "MLXVoiceCoreTests", dependencies: ["MLXVoiceCore"]),
        .testTarget(
            name: "MLXVoiceOrchestrationTests",
            dependencies: ["MLXVoiceCore", "MLXVoiceOrchestration"]
        ),
    ]
)
