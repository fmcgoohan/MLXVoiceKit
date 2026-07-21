# MLXVoiceKit

Native, in-process [Qwen3-TTS](https://huggingface.co/mlx-community) text-to-speech
on Apple Silicon via [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift).
Model download from Hugging Face, a hardware-aware memory budget, custom
voice-profile conditioning, and a real-time PCM streaming player.

| Product | What it gives you |
|---|---|
| `MLXVoiceCore` | The session-agnostic engine: `NativeMLXProvider` (load/stream), `PCMStreamPlayer` (adaptive-rate, seekable playback), `NativeMemoryBudget`, voice profiles/designer, and benchmarking. |
| `MLXVoiceOrchestration` | A `ReadingSession`-based state machine on top of the core — chunking, playback, checkpointing, model retention. Depends on [`SwiftReadingSession`](https://github.com/fmcgoohan/SwiftSpeechSuite). |

Need only raw synthesis? Depend on `MLXVoiceCore` alone and skip the session graph.

## Requirements

- An Apple-silicon Mac with **≥ 16 GB** unified memory for native generation.
- macOS 26+.
- **Metal toolchain.** MLX's Metal shaders require an Xcode-based build. Install
  the toolchain once with `xcodebuild -downloadComponent MetalToolchain`. A bare
  `swift run` executable compiles but cannot load MLX's default Metal library.

## Installation

```swift
.package(url: "https://github.com/fmcgoohan/MLXVoiceKit.git", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "MLXVoiceCore", package: "MLXVoiceKit"),
    .product(name: "MLXVoiceOrchestration", package: "MLXVoiceKit"), // optional
])
```

## Branding the injectable defaults

```swift
NativeVoiceProfileStore.applicationSupportSubdirectory = "MyApp"
```

## License

MIT — see [LICENSE](LICENSE). Note the transitive MLX / Hugging Face graph
(`mlx-swift`, `swift-transformers`, …) carries its own licenses.
