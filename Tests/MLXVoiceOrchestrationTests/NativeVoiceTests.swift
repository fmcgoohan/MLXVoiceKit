@preconcurrency import AVFAudio
import Foundation
import SwiftSpeechKit
import SwiftReadingSession
import Testing
@testable import MLXVoiceCore
@testable import MLXVoiceOrchestration

@MainActor
private final class UnloadCounter {
    var value = 0
}

@Test func pcmChunkDurationUsesSampleRate() {
    let chunk = PCMChunk(samples: [Float](repeating: 0, count: 12_000), sampleRate: 24_000)
    #expect(chunk.duration == 0.5)
}

@Test func nativeMemoryBudgetScalesWithUnifiedMemory() {
    let gibibyte = UInt64(1_024 * 1_024 * 1_024)
    let unsupported = NativeMemoryBudget(physicalMemoryBytes: 8 * gibibyte)
    let constrained = NativeMemoryBudget(physicalMemoryBytes: 16 * gibibyte)
    let standard = NativeMemoryBudget(physicalMemoryBytes: 24 * gibibyte)
    let highCapacity = NativeMemoryBudget(physicalMemoryBytes: 32 * gibibyte)

    #expect(unsupported.hardwareTier == .unsupported)
    #expect(!unsupported.supportsNativeMLX)
    #expect(unsupported.cacheLimitBytes == 128 * 1_024 * 1_024)
    #expect(constrained.hardwareTier == .constrained)
    #expect(constrained.supportsNativeMLX)
    #expect(constrained.cacheLimitBytes == 256 * 1_024 * 1_024)
    #expect(standard.hardwareTier == .standard)
    #expect(standard.cacheLimitBytes == 512 * 1_024 * 1_024)
    #expect(highCapacity.hardwareTier == .highCapacity)
    #expect(highCapacity.cacheLimitBytes == 1_024 * 1_024 * 1_024)
}

@Test @MainActor func idleModelUnloaderFiresWhenModelRemainsIdle() async {
    let counter = UnloadCounter()
    let unloader = NativeModelIdleUnloader(delay: .milliseconds(20))
    unloader.reconcile(keepLoaded: false, isIdle: true, isLoaded: true) {
        counter.value += 1
    }

    for _ in 0..<20 where counter.value == 0 {
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(counter.value == 1)
}

@Test @MainActor func idleModelUnloaderCancelsForActivityOrKeepLoaded() async {
    let counter = UnloadCounter()
    let unloader = NativeModelIdleUnloader(delay: .milliseconds(20))
    unloader.reconcile(keepLoaded: false, isIdle: true, isLoaded: true) {
        counter.value += 1
    }
    unloader.reconcile(keepLoaded: false, isIdle: false, isLoaded: true) {
        counter.value += 1
    }
    try? await Task.sleep(for: .milliseconds(40))
    #expect(counter.value == 0)

    unloader.reconcile(keepLoaded: true, isIdle: true, isLoaded: true) {
        counter.value += 1
    }
    try? await Task.sleep(for: .milliseconds(40))
    #expect(counter.value == 0)
}

@Test @MainActor func providerRejectsHardwareBelowSixteenGBBeforeLoading() async {
    let provider = NativeMLXProvider(
        modelID: "unused-in-this-test",
        memoryBudget: NativeMemoryBudget(physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024)
    )
    await #expect(throws: NativeMLXProviderError.unsupportedPhysicalMemory(
        requiredBytes: 16 * 1_024 * 1_024 * 1_024,
        availableBytes: 8 * 1_024 * 1_024 * 1_024
    )) {
        try await provider.load()
    }
}

@Test @MainActor func highPlaybackRatesUseMoreQualityAndPrebuffering() {
    #expect(PCMStreamPlayer.minimumBufferedAudioSeconds(for: 1) == 0.25)
    #expect(PCMStreamPlayer.minimumBufferedAudioSeconds(for: 1.5) == 6)
    #expect(PCMStreamPlayer.minimumBufferedAudioSeconds(for: 2) == 8)
    #expect(PCMStreamPlayer.recoveryBufferedAudioSeconds(for: 1) == 4)
    #expect(PCMStreamPlayer.recoveryBufferedAudioSeconds(for: 1.5) == 8)
    #expect(PCMStreamPlayer.recoveryBufferedAudioSeconds(for: 2) == 10)
    #expect(PCMStreamPlayer.coldStartBufferedAudioSeconds(for: 1) == 10)
    #expect(PCMStreamPlayer.coldStartBufferedAudioSeconds(for: 1.5) == 12)
    #expect(PCMStreamPlayer.coldStartBufferedAudioSeconds(for: 2) == 14)
    // Overlap is rate-independent and set once at engine setup — live
    // mutation corrupts AVAudioUnitTimePitch (fix/timepitch-overlap).
    #expect(PCMStreamPlayer.fixedTimePitchOverlap == 32)
}

@Test @MainActor func appUsesLargerPCMChunksAtHighPlaybackRates() {
    #expect(NativeVoiceEngine.streamingInterval(for: 1) == 1)
    #expect(NativeVoiceEngine.streamingInterval(for: 1.25) == 1)
    #expect(NativeVoiceEngine.streamingInterval(for: 1.5) == 2)
    #expect(NativeVoiceEngine.streamingInterval(for: 2) == 2)
}

@Test @MainActor func nativeRunAheadIsRateAwareAndPausedGenerationBackpressures() {
    #expect(NativeVoiceEngine.queuedAudioSecondsLimit(for: 1) == 8)
    #expect(NativeVoiceEngine.queuedAudioSecondsLimit(for: 1.25) == 10)
    #expect(NativeVoiceEngine.queuedAudioSecondsLimit(for: 1.5) == 12)
    #expect(NativeVoiceEngine.queuedAudioSecondsLimit(for: 1.75) == 14)
    #expect(NativeVoiceEngine.queuedAudioSecondsLimit(for: 2) == 16)

    #expect(PCMStreamPlayer.shouldWaitForQueueCapacity(
        started: true,
        paused: true,
        queuedAudioSeconds: 1,
        maximumQueuedAudioSeconds: 10
    ))
    #expect(PCMStreamPlayer.shouldWaitForQueueCapacity(
        started: true,
        paused: false,
        queuedAudioSeconds: 10,
        maximumQueuedAudioSeconds: 10
    ))
    #expect(!PCMStreamPlayer.shouldWaitForQueueCapacity(
        started: true,
        paused: false,
        queuedAudioSeconds: 9.9,
        maximumQueuedAudioSeconds: 10
    ))
}

@Test @MainActor func exhaustedPCMQueueEntersOneRebufferingCycle() {
    #expect(PCMStreamPlayer.shouldEnterRebuffering(
        inputFinished: false,
        paused: false,
        hasStartedPlayback: true,
        queuedBuffers: 0,
        waitingForAudio: false
    ))
    #expect(!PCMStreamPlayer.shouldEnterRebuffering(
        inputFinished: false,
        paused: false,
        hasStartedPlayback: true,
        queuedBuffers: 0,
        waitingForAudio: true
    ))
    #expect(!PCMStreamPlayer.shouldEnterRebuffering(
        inputFinished: true,
        paused: false,
        hasStartedPlayback: true,
        queuedBuffers: 0,
        waitingForAudio: false
    ))
}

@Test @MainActor func readingSessionCacheWritesCanonicalPCMAndManifest() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("speakflow-session-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var session = ReadingSession(
        text: "Cached speech.",
        backend: .nativeMLX,
        segmentTexts: ["Cached speech."]
    )
    let cache = try ReadingSessionAudioCache(sessionID: session.id, baseDirectory: root)
    let chunk = PCMChunk(samples: [Float](repeating: 0.1, count: 2_400), sampleRate: 24_000)
    cache.append(chunk, segmentIndex: 0)
    cache.finishSegment(0)
    try await cache.flush()
    session.recordGeneratedAudio(segmentIndex: 0, seconds: chunk.duration)
    session.markAudioComplete(segmentIndex: 0)
    try cache.persist(session)

    let audio = try AVAudioFile(forReading: cache.audioURL(segmentIndex: 0))
    #expect(audio.length == 2_400)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let saved = try decoder.decode(
        ReadingSession.self,
        from: Data(contentsOf: cache.directoryURL.appendingPathComponent("manifest.json"))
    )
    #expect(saved.id == session.id)
    #expect(saved.text == session.text)
    #expect(saved.backend == session.backend)
    #expect(saved.segments == session.segments)
    #expect(abs(saved.createdAt.timeIntervalSince(session.createdAt)) < 1)
}

@Test @MainActor func longWebPageIsSplitIntoBoundedSequentialNativeRequests() {
    let sentence = "This is representative article prose with enough words to exercise segmentation."
    let text = Array(repeating: sentence, count: 360).joined(separator: " ")
    let requests = NativeVoiceEngine.synthesisRequests(for: text)

    #expect(text.count > 26_000)
    #expect(requests.count > 30)
    #expect(requests.allSatisfy { $0.count <= 800 })
    #expect(requests.joined(separator: " ") == text)
}

@Test func unloadedProviderRejectsStreaming() async {
    await MainActor.run {
        let provider = NativeMLXProvider(modelID: "unused-in-this-test")
        #expect(throws: NativeMLXProviderError.modelNotLoaded) {
            _ = try provider.stream(NativeSpeechRequest(text: "Hello"))
        }
    }
}

@Test @MainActor func invalidModelIDFailsBeforeDownload() async {
    let progressHandler: @MainActor @Sendable (Double) -> Void = { _ in }
    let provider = NativeMLXProvider(modelID: "")
    await #expect(throws: NativeMLXProviderError.invalidModelID("")) {
        try await provider.prepare(progressHandler: progressHandler)
    }
}

@Test @MainActor func qwenBaseRequiresAUsableVoiceProfileBeforeDownload() async {
    let progressHandler: @MainActor @Sendable (Double) -> Void = { _ in }
    let provider = NativeMLXProvider(modelID: NativeMLXProvider.baseVoiceModelID)
    await #expect(throws: NativeMLXProviderError.voiceProfileRequired(NativeMLXProvider.baseVoiceModelID)) {
        try await provider.prepare(progressHandler: progressHandler)
    }
}

@Test func nativeVoiceProfileInstallsAndLoads() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let candidateURL = root.appendingPathComponent("candidate.wav")
    try Data("test-wave-data".utf8).write(to: candidateURL)
    let candidate = NativeVoiceCandidate(
        audioURL: candidateURL,
        referenceText: "Exact spoken text.",
        designPrompt: "American female narrator.",
        sourceModelID: NativeVoiceDesigner.defaultModelID
    )
    let installed = try NativeVoiceProfileStore.install(
        candidate,
        directoryURL: root.appendingPathComponent("installed", isDirectory: true),
        createdAt: Date(timeIntervalSince1970: 123)
    )
    let loaded = try NativeVoiceProfileStore.load(from: installed.profileURL)

    #expect(loaded == installed.profile)
    #expect(loaded.name == "American Narrator")
    #expect(loaded.referenceText == candidate.referenceText)
    #expect(loaded.isUsable)
}

@Test func benchmarkMarkdownIncludesComparisonFields() {
    let result = VoiceBenchmarkResult(
        backend: "native-mlx",
        model: "test-model",
        iteration: 1,
        modelLoadSeconds: 2,
        timeToFirstAudioSeconds: 0.2,
        generationSeconds: 1,
        audioSeconds: 3,
        realtimeMultiple: 3,
        audioChunkCount: 4,
        tokensPerSecond: 10,
        peakMemoryGB: 1.5
    )
    let markdown = VoiceBenchmarkReport(
        generatedAt: Date(timeIntervalSince1970: 0),
        text: "Hello",
        results: [result]
    ).markdown()

    #expect(markdown.contains("| Backend | Model |"))
    #expect(markdown.contains("native-mlx"))
    #expect(markdown.contains("3.00x"))
}

@Test func acceptanceReportIncludesPlaybackLifecycleAndEnforceableChecks() {
    let text = String(repeating: "Long-form acceptance text. ", count: 40)
    let result = VoiceBenchmarkResult(
        backend: "native-mlx",
        model: "test-model",
        iteration: 1,
        timeToFirstAudioSeconds: 0.2,
        generationSeconds: 10,
        audioSeconds: 12,
        realtimeMultiple: 1.2,
        audioChunkCount: 40,
        characterCount: text.count,
        requestCount: 3,
        targetPlaybackRate: 2,
        playbackSeconds: 7,
        deliveredPlaybackMultiple: 1.71,
        adaptivePlaybackSeconds: 2,
        minimumEffectivePlaybackRate: 1.25,
        underrunCount: 0
    )
    let diagnostics = NativeBenchmarkDiagnostics(
        physicalMemoryGB: 34.36,
        hardwareTier: .highCapacity,
        cacheLimitGB: 1.074,
        cancellationAfterSeconds: 2,
        cancellationResponseSeconds: 0.05,
        cancellationSucceeded: true,
        activeMemoryBeforeLoadGB: 0,
        activeMemoryAfterLoadGB: 3,
        activeMemoryAfterUnloadGB: 0.1,
        cacheMemoryAfterUnloadGB: 0
    )
    let report = VoiceBenchmarkReport(
        generatedAt: Date(timeIntervalSince1970: 0),
        text: text,
        results: [result],
        nativeDiagnostics: diagnostics
    )
    let markdown = report.markdown()

    #expect(markdown.contains("## Live PCM playback"))
    #expect(markdown.contains("Delivered speed includes any PCM starvation gaps"))
    #expect(markdown.contains("Cancellation after 2.000s: passed"))
    #expect(markdown.contains("Physical memory: 34.360 GB (High capacity)"))
    #expect(markdown.contains("MLX cache limit: 1.074 GB"))
    #expect(markdown.contains("PASS: Continuous live PCM playback"))
    #expect(markdown.contains("PASS: MLX cache within hardware budget"))
    #expect(report.acceptanceFailures.isEmpty)
}
