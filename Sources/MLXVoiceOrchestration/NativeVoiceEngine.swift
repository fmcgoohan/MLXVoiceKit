import AppKit
import SwiftSpeechKit
import Combine
import Foundation
import SwiftLogKit
import MLXVoiceCore
import SwiftReadingSession

@MainActor
public final class NativeVoiceEngine: ObservableObject {
    private static let firstRequestTarget = 350
    private static let requestTarget = 600
    private static let hardSplitLimit = 800
    public static let maximumQueuedAudioSeconds: TimeInterval = 16

    public static func queuedAudioSecondsLimit(for playbackRate: Float) -> TimeInterval {
        switch PlaybackRate.normalized(playbackRate) {
        case ..<1.25: 8
        case ..<1.5: 10
        case ..<1.75: 12
        case ..<2: 14
        default: maximumQueuedAudioSeconds
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case preparing
        case synthesizing
        case speaking
        case paused
    }

    public enum ModelState: Sendable, Equatable {
        case notDownloaded
        case downloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published public private(set) var state: State = .idle {
        didSet { reconcileModelRetention() }
    }
    @Published public private(set) var modelState: ModelState {
        didSet { reconcileModelRetention() }
    }
    @Published public private(set) var lastUtteranceSummary: String?
    @Published public private(set) var readingSession: ReadingSession?
    @Published public private(set) var sessionCacheURL: URL?

    @Published public private(set) var modelID: String
    @Published public private(set) var voiceProfileName: String?

    private var provider: NativeMLXProvider
    private var player: PCMStreamPlayer?
    private var preparationTask: Task<Void, Error>?
    private var speechTask: Task<Void, Never>?
    private var speechGeneration = 0
    private var sessionCache: ReadingSessionAudioCache?
    private var receivedAudio = false
    private var configurationGeneration = 0
    private var playbackRate: Float
    private var keepModelLoaded = false
    private let idleUnloader = NativeModelIdleUnloader()

    public init(
        modelID: String = NativeMLXProvider.defaultModelID,
        voiceProfile: NativeVoiceProfile? = nil,
        playbackRate: Float = 1
    ) {
        self.modelID = modelID
        self.voiceProfileName = voiceProfile?.name
        self.playbackRate = PlaybackRate.normalized(playbackRate)
        let provider = NativeMLXProvider(modelID: modelID, voiceProfile: voiceProfile)
        self.provider = provider
        self.modelState = provider.isDownloaded ? .downloaded : .notDownloaded
    }

    public var isBusy: Bool { state != .idle }
    public var isModelLoaded: Bool { provider.isLoaded }
    public var hasVoiceProfile: Bool { provider.hasVoiceProfile }

    public func setKeepModelLoaded(_ keepLoaded: Bool) {
        keepModelLoaded = keepLoaded
        reconcileModelRetention()
    }

    public func configure(modelID: String, voiceProfile: NativeVoiceProfile?) {
        stop()
        configurationGeneration += 1
        preparationTask?.cancel()
        preparationTask = nil
        provider.unload()

        self.modelID = modelID
        self.voiceProfileName = voiceProfile?.name
        let provider = NativeMLXProvider(modelID: modelID, voiceProfile: voiceProfile)
        self.provider = provider
        modelState = provider.isDownloaded ? .downloaded : .notDownloaded
        lastUtteranceSummary = nil
    }

    public func prepareModel() {
        guard !provider.isLoaded, preparationTask == nil else { return }
        let generation = configurationGeneration
        Task { @MainActor [weak self] in
            guard let self, self.configurationGeneration == generation else { return }
            do {
                try await self.ensureModelReady()
            } catch is CancellationError {
                guard self.configurationGeneration == generation else { return }
                self.refreshModelState()
            } catch {
                guard self.configurationGeneration == generation else { return }
                self.modelState = .failed(error.localizedDescription)
                SFLog.pipeline.error("native voice preparation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func unloadModel() {
        idleUnloader.cancel()
        stop()
        configurationGeneration += 1
        preparationTask?.cancel()
        preparationTask = nil
        provider.unload()
        refreshModelState()
        SFLog.pipeline.notice("native voice model unloaded")
    }

    /// Starts immediately from the caller's perspective so the app-wide
    /// busy guard cannot launch a second engine while preparation is pending.
    public func speak(
        text: String,
        voice: String?,
        language: String? = "English",
        source: ReadingSource = ReadingSource(),
        translation: ReadingTranslation? = nil,
        continuedFromSessionID: UUID? = nil,
        onFailure: (@MainActor (Error, Bool) -> Void)? = nil
    ) {
        guard state == .idle else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        state = provider.isLoaded ? .synthesizing : .preparing
        speechGeneration += 1
        let activeSpeechGeneration = speechGeneration
        receivedAudio = false
        lastUtteranceSummary = nil
        let start = ContinuousClock.now
        let requests = Self.synthesisRequests(for: text)
        let session = ReadingSession(
            text: text,
            translation: translation,
            backend: .nativeMLX,
            source: source,
            voiceName: voiceProfileName ?? voice,
            modelID: modelID,
            continuedFromSessionID: continuedFromSessionID,
            playbackRate: playbackRate,
            segmentTexts: requests
        )
        readingSession = session
        do {
            let cache = try ReadingSessionAudioCache(sessionID: session.id)
            sessionCache = cache
            sessionCacheURL = cache.directoryURL
            try cache.persist(session)
        } catch {
            sessionCache = nil
            sessionCacheURL = nil
            SFLog.pipeline.warning("native session cache unavailable: \(error.localizedDescription, privacy: .public)")
        }

        speechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await ensureModelReady()
                try Task.checkCancellation()
                if state != .paused { state = .synthesizing }

                var chunkCount = 0
                var audioSeconds: TimeInterval = 0
                var firstAudioSeconds: TimeInterval?
                var generationSeconds: TimeInterval = 0
                var underrunCount = 0
                let player = PCMStreamPlayer()
                self.player = player
                player.setPlaybackRate(playbackRate)
                player.onPlaybackStarted = { [weak self] in
                    guard let self, self.speechGeneration == activeSpeechGeneration else { return }
                    if firstAudioSeconds == nil {
                        firstAudioSeconds = Self.seconds(since: start)
                    }
                    if state != .paused {
                        state = .speaking
                    }
                }
                player.onPlaybackProgress = { [weak self] segmentIndex, seconds in
                    guard let self, self.speechGeneration == activeSpeechGeneration else { return }
                    self.recordPlayback(segmentIndex: segmentIndex, seconds: seconds)
                }
                player.onSegmentFinished = { [weak self] segmentIndex in
                    guard let self, self.speechGeneration == activeSpeechGeneration else { return }
                    self.markPlaybackComplete(segmentIndex: segmentIndex)
                }
                player.onUnderrun = { [weak self] in
                    guard let self, self.speechGeneration == activeSpeechGeneration else { return }
                    underrunCount += 1
                    SFLog.pipeline.warning(
                        "native PCM queue exhausted at \(self.playbackRate, privacy: .public)x target; pausing to rebuild the reservoir"
                    )
                }
                player.onSeekCompleted = { [weak self] segmentIndex, offsetWithinSegment in
                    guard let self, self.speechGeneration == activeSpeechGeneration else { return }
                    self.readingSession?.seekPlayback(
                        segmentIndex: segmentIndex,
                        audioSeconds: offsetWithinSegment
                    )
                    self.persistSession()
                }
                try player.start()
                if state == .paused { player.pause() }

                SFLog.pipeline.notice(
                    "native voice segmented \(text.count, privacy: .public) chars into \(requests.count, privacy: .public) sequential requests"
                )

                for (requestIndex, requestText) in requests.enumerated() {
                    let requestStart = ContinuousClock.now
                    let requestAudioStart = audioSeconds
                    try await player.waitForQueueCapacity(
                        maximumQueuedAudioSeconds: Self.queuedAudioSecondsLimit(for: playbackRate)
                    )
                    let events = try provider.stream(NativeSpeechRequest(
                        text: requestText,
                        voice: voice,
                        language: language,
                        streamingInterval: Self.streamingInterval(for: playbackRate)
                    ))
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .audio(let chunk):
                            try await player.waitForQueueCapacity(
                                maximumQueuedAudioSeconds: Self.queuedAudioSecondsLimit(for: playbackRate)
                            )
                            cacheAudio(chunk, segmentIndex: requestIndex)
                            readingSession?.recordGeneratedAudio(
                                segmentIndex: requestIndex,
                                seconds: chunk.duration
                            )
                            try player.enqueue(chunk, segmentIndex: requestIndex)
                            chunkCount += 1
                            audioSeconds += chunk.duration
                            if !receivedAudio {
                                receivedAudio = true
                                if state == .paused {
                                    player.pause()
                                }
                            }
                        case .statistics(let value):
                            generationSeconds += value.generationSeconds
                        }
                    }
                    sessionCache?.finishSegment(requestIndex)
                    readingSession?.markAudioComplete(segmentIndex: requestIndex)
                    player.markSegmentInputFinished(requestIndex)
                    persistSession()
                    SFLog.pipeline.notice(
                        "native request \(requestIndex + 1, privacy: .public)/\(requests.count, privacy: .public) generated \(audioSeconds - requestAudioStart, privacy: .public)s audio in \(Self.seconds(since: requestStart), privacy: .public)s; PCM reservoir \(player.queuedAudioSeconds, privacy: .public)s at \(player.effectivePlaybackRate, privacy: .public)x effective"
                    )
                }

                try Task.checkCancellation()
                try await player.finishInput()
                try Task.checkCancellation()
                let wallSeconds = Self.seconds(since: start)
                let first = firstAudioSeconds ?? wallSeconds
                let realtime = generationSeconds > 0
                    ? audioSeconds / max(generationSeconds, 0.001)
                    : nil
                lastUtteranceSummary = Self.summary(
                    requests: requests.count,
                    chunks: chunkCount,
                    firstAudioSeconds: first,
                    wallSeconds: wallSeconds,
                    realtime: realtime,
                    underruns: underrunCount
                )
                SFLog.pipeline.notice("native voice done: \(self.lastUtteranceSummary ?? "", privacy: .public)")
                finishSpeech(status: .completed, generation: activeSpeechGeneration)
            } catch is CancellationError {
                finishSpeech(status: .stopped, generation: activeSpeechGeneration)
            } catch {
                guard speechGeneration == activeSpeechGeneration else { return }
                SFLog.pipeline.error("native voice failed: \(error.localizedDescription, privacy: .public)")
                let failedAfterAudioStarted = receivedAudio
                finishSpeech(status: .stopped, generation: activeSpeechGeneration)
                onFailure?(error, failedAfterAudioStarted)
            }
        }
    }

    public func pause() {
        switch state {
        case .preparing, .synthesizing, .speaking:
            player?.pause()
            state = .paused
            readingSession?.status = .paused
            persistSession()
        case .idle, .paused:
            break
        }
    }

    public func resume() {
        guard state == .paused else { return }
        player?.resume()
        if receivedAudio {
            state = .speaking
        } else {
            state = provider.isLoaded ? .synthesizing : .preparing
        }
        readingSession?.status = .reading
        persistSession()
    }

    public func stop() {
        speechGeneration += 1
        speechTask?.cancel()
        speechTask = nil
        player?.stop()
        player = nil
        readingSession?.status = .stopped
        persistSession()
        sessionCache = nil
        receivedAudio = false
        state = .idle
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = PlaybackRate.normalized(rate)
        player?.setPlaybackRate(playbackRate)
        readingSession?.playbackRate = playbackRate
        persistSession()
    }

    /// True whenever the underlying PCM player has enough retained history
    /// for `seek(by:)` to produce a meaningful jump. Session checkpoints
    /// are updated by the player's `onSeekCompleted` callback.
    public var canSeek: Bool { player?.canSeek == true }

    /// Seek playback by `offset` audio seconds. Synthesis continues in the
    /// background; playback is repositioned within the retained history
    /// (rewind) or scheduled inflight buffers (fast-forward), clamped to
    /// the current generation front.
    public func seek(by offset: TimeInterval) {
        player?.seek(by: offset)
    }

    private func ensureModelReady() async throws {
        let activeProvider = provider
        let generation = configurationGeneration
        if activeProvider.isLoaded {
            modelState = .ready
            return
        }
        if let preparationTask {
            try await preparationTask.value
            return
        }

        let task = Task { @MainActor [activeProvider, weak self] in
            _ = try await activeProvider.prepare { [weak self] fraction in
                guard let self, self.configurationGeneration == generation else { return }
                self.modelState = fraction < 1 ? .downloading(fraction) : .loading
            }
        }
        preparationTask = task
        defer {
            if configurationGeneration == generation {
                preparationTask = nil
            }
        }
        do {
            try await task.value
            guard configurationGeneration == generation, provider === activeProvider else {
                activeProvider.unload()
                throw CancellationError()
            }
            modelState = .ready
        } catch is CancellationError {
            activeProvider.unload()
            if configurationGeneration == generation {
                refreshModelState()
            }
            throw CancellationError()
        } catch {
            if configurationGeneration == generation {
                modelState = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func refreshModelState() {
        if provider.isLoaded {
            modelState = .ready
        } else {
            modelState = provider.isDownloaded ? .downloaded : .notDownloaded
        }
    }

    private func reconcileModelRetention() {
        idleUnloader.reconcile(
            keepLoaded: keepModelLoaded,
            isIdle: state == .idle,
            isLoaded: provider.isLoaded
        ) { [weak self] in
            guard let self,
                  !self.keepModelLoaded,
                  self.state == .idle,
                  self.provider.isLoaded
            else { return }
            self.provider.unload()
            self.refreshModelState()
            SFLog.pipeline.notice("native voice model unloaded after 10 idle minutes")
        }
    }

    private func finishSpeech(status: ReadingSessionStatus, generation: Int) {
        guard speechGeneration == generation else { return }
        player?.stop()
        player = nil
        speechTask = nil
        readingSession?.status = status
        persistSession()
        sessionCache = nil
        receivedAudio = false
        state = .idle
    }

    private func cacheAudio(_ chunk: PCMChunk, segmentIndex: Int) {
        guard let sessionCache else { return }
        sessionCache.append(chunk, segmentIndex: segmentIndex) { [weak self, weak sessionCache] error in
            Task { @MainActor in
                guard let self, let sessionCache, self.sessionCache === sessionCache else { return }
                SFLog.pipeline.warning("native session cache write failed: \(error.localizedDescription, privacy: .public)")
                self.sessionCache = nil
                self.sessionCacheURL = nil
            }
        }
    }

    private func recordPlayback(segmentIndex: Int, seconds: TimeInterval) {
        readingSession?.recordPlayback(segmentIndex: segmentIndex, seconds: seconds)
    }

    private func markPlaybackComplete(segmentIndex: Int) {
        readingSession?.markPlaybackComplete(segmentIndex: segmentIndex)
        persistSession()
    }

    private func persistSession() {
        guard let readingSession, let sessionCache else { return }
        do {
            try sessionCache.persist(readingSession)
        } catch {
            SFLog.pipeline.warning("native session checkpoint write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    public static func synthesisRequests(for text: String) -> [String] {
        SpeechTextChunker.chunk(
            text,
            firstTarget: firstRequestTarget,
            target: requestTarget,
            hardSplitLimit: hardSplitLimit
        )
    }

    static func streamingInterval(for playbackRate: Float) -> TimeInterval {
        PlaybackRate.normalized(playbackRate) >= 1.5 ? 2 : 1
    }

    private static func summary(
        requests: Int,
        chunks: Int,
        firstAudioSeconds: TimeInterval,
        wallSeconds: TimeInterval,
        realtime: Double?,
        underruns: Int
    ) -> String {
        let speed = realtime.map { String(format: ", %.2fx realtime", $0) } ?? ""
        let underrunSummary = underruns > 0 ? ", \(underruns) underruns" : ""
        return String(
            format: "%d requests, %d PCM chunks, first audio %.2fs, total %.2fs%@%@",
            requests,
            chunks,
            firstAudioSeconds,
            wallSeconds,
            speed,
            underrunSummary
        )
    }
}
