# MLXVoiceKit

[![CI](https://github.com/fmcgoohan/MLXVoiceKit/actions/workflows/ci.yml/badge.svg)](https://github.com/fmcgoohan/MLXVoiceKit/actions/workflows/ci.yml)
![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2026%2B%20·%20Apple%20Silicon-blue.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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

## Usage

### MLXVoiceCore — stream PCM from text

```swift
import MLXVoiceCore

let provider = NativeMLXProvider() // defaults to a Qwen3-TTS model id
_ = try await provider.prepare { fraction in print("download \(fraction)") }

for try await event in try provider.stream(NativeSpeechRequest(text: "Hello.")) {
    if case .audio(let chunk) = event {
        // chunk.samples: [Float], chunk.sampleRate: Int, chunk.duration: TimeInterval
        play(chunk.samples, at: chunk.sampleRate)
    }
}
```

### MLXVoiceOrchestration — a session-backed engine

```swift
import MLXVoiceOrchestration

let engine = NativeVoiceEngine()          // @MainActor ObservableObject
engine.speak(text: "Read this aloud.", voice: nil)
// engine.pause() / resume() / stop() / setPlaybackRate(_:) / seek(by:)
// engine.readingSession is a SwiftReadingSession.ReadingSession you can persist.
```

## Branding the injectable defaults

```swift
NativeVoiceProfileStore.applicationSupportSubdirectory = "MyApp"
```

## Documentation

Rendered API docs (DocC) for both products:
**https://fmcgoohan.github.io/MLXVoiceKit/documentation/**

Built and published to GitHub Pages by `.github/workflows/docs.yml` on push to `main`.

## License

MIT — see [LICENSE](LICENSE). Note the transitive MLX / Hugging Face graph
(`mlx-swift`, `swift-transformers`, …) carries its own licenses.
