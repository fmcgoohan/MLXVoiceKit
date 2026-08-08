@preconcurrency import AVFAudio
import Foundation
import SwiftSpeechKit
import MLXAudioCore

/// Schedules PCM frames as the model emits them. No temporary WAV files or
/// per-sentence decode step sit between generation and the audio device.
@MainActor
public final class PCMStreamPlayer {
    /// Rolling in-memory history retained per session so `seek(by:)` can
    /// rewind into audio that has already played. Bounded by audio seconds
    /// (rather than count) so playback-rate and chunk-size changes cannot
    /// inflate memory: 60 s of float32 mono at 24 kHz is roughly 5.7 MB.
    public static let historyAudioSecondsLimit: TimeInterval = 60

    struct RetainedFrame {
        let buffer: AVAudioPCMBuffer
        let segmentIndex: Int
        let duration: TimeInterval
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var converter: PCMStreamConverter?
    private var queuedBuffers = 0
    public private(set) var queuedAudioSeconds: TimeInterval = 0
    private var queuedBuffersBySegment: [Int: Int] = [:]
    private var inputFinishedSegments: Set<Int> = []
    private var reportedFinishedSegments: Set<Int> = []
    private var lastSegmentIndex = 0
    private var inputFinished = false
    private var started = false
    private var paused = false
    private var hasStartedPlayback = false
    private var waitingForAudio = false
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private let waitsForInitialSegment: Bool
    /// Played frames retained oldest-first, bounded by cumulative duration.
    private var historyFrames: [RetainedFrame] = []
    private var historyAudioSeconds: TimeInterval = 0
    /// Frames scheduled to the player node but not yet played, oldest-first.
    /// Buffers finish in schedule order, so this is a FIFO whose head is
    /// removed by the next `.dataPlayedBack` callback.
    private var inflightFrames: [RetainedFrame] = []
    /// Bumped every time we tear down the node's schedule (stop or seek).
    /// Stale `.dataPlayedBack` callbacks from before the tear-down check
    /// this generation and no-op instead of corrupting history state.
    private var scheduleGeneration = 0
    public var onPlaybackStarted: (@MainActor () -> Void)?
    public var onPlaybackProgress: (@MainActor (Int, TimeInterval) -> Void)?
    public var onSegmentFinished: (@MainActor (Int) -> Void)?
    public var onUnderrun: (@MainActor () -> Void)?
    public var onEffectivePlaybackRateChanged: (@MainActor (Float) -> Void)?
    /// Fires after `seek(by:)` resolves so the engine can update its
    /// `ReadingSession` checkpoint. `offsetWithinSegment` is expressed in
    /// 1x audio seconds, matching the units `ReadingSession` expects.
    public var onSeekCompleted: (@MainActor (_ segmentIndex: Int, _ offsetWithinSegment: TimeInterval) -> Void)?
    public private(set) var playbackRate: Float = 1
    public private(set) var effectivePlaybackRate: Float = 1

    public init(waitsForInitialSegment: Bool = false) {
        self.waitsForInitialSegment = waitsForInitialSegment
        engine.attach(player)
        engine.attach(timePitch)
    }

    /// True once at least one buffer has been played, so `seek(by:)` has a
    /// meaningful frame of reference. Stays true across pause/resume until
    /// the session ends.
    public var canSeek: Bool {
        started && !historyFrames.isEmpty
    }

    public func start() throws {
        guard !started else { return }
        let output = engine.outputNode
        let outputFormat = output.inputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            throw PCMStreamPlayerError.audioOutputUnavailable
        }
        engine.connect(player, to: timePitch, format: outputFormat)
        engine.connect(timePitch, to: output, format: outputFormat)
        effectivePlaybackRate = playbackRate
        timePitch.rate = effectivePlaybackRate
        timePitch.overlap = Self.fixedTimePitchOverlap
        converter = PCMStreamConverter(outputFormat: outputFormat)
        engine.prepare()
        try engine.start()
        started = true
        paused = false
        hasStartedPlayback = false
        waitingForAudio = false
    }

    public func enqueue(_ chunk: PCMChunk, segmentIndex: Int = 0) throws {
        guard started, let converter else { throw PCMStreamPlayerError.notStarted }
        guard !chunk.samples.isEmpty else { return }
        lastSegmentIndex = segmentIndex
        let input = try Self.makeBuffer(chunk)
        for buffer in try converter.push(input) {
            schedule(buffer, segmentIndex: segmentIndex)
        }
    }

    public func markSegmentInputFinished(_ segmentIndex: Int) {
        inputFinishedSegments.insert(segmentIndex)
        reportFinishedSegmentIfReady(segmentIndex)
        if !hasStartedPlayback {
            startPlaybackIfReady(force: true)
        }
    }

    /// Prevent long-form generation from queuing minutes of converted audio
    /// ahead of the speaker. Pausing also applies backpressure to inference at
    /// the next streamed chunk instead of filling the entire reservoir.
    public func waitForQueueCapacity(maximumQueuedAudioSeconds: TimeInterval) async throws {
        let limit = max(0.25, maximumQueuedAudioSeconds)
        while Self.shouldWaitForQueueCapacity(
            started: started,
            paused: paused,
            queuedAudioSeconds: queuedAudioSeconds,
            maximumQueuedAudioSeconds: limit
        ) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
    }

    static func shouldWaitForQueueCapacity(
        started: Bool,
        paused: Bool,
        queuedAudioSeconds: TimeInterval,
        maximumQueuedAudioSeconds: TimeInterval
    ) -> Bool {
        started && (paused || queuedAudioSeconds >= max(0.25, maximumQueuedAudioSeconds))
    }

    public func finishInput() async throws {
        guard started, let converter else { throw PCMStreamPlayerError.notStarted }
        for buffer in try converter.finish() {
            schedule(buffer, segmentIndex: lastSegmentIndex)
        }
        inputFinished = true
        updateAdaptivePlaybackRate()
        startPlaybackIfReady(force: true)
        guard queuedBuffers > 0 else {
            stopEngine()
            return
        }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    public func pause() {
        paused = true
        player.pause()
    }

    public func resume() {
        guard started else { return }
        paused = false
        startPlaybackIfReady(force: inputFinished)
    }

    public func stop() {
        player.stop()
        queuedBuffers = 0
        queuedAudioSeconds = 0
        queuedBuffersBySegment.removeAll()
        inputFinishedSegments.removeAll()
        reportedFinishedSegments.removeAll()
        inputFinished = false
        paused = false
        hasStartedPlayback = false
        waitingForAudio = false
        scheduleGeneration += 1
        inflightFrames.removeAll()
        historyFrames.removeAll()
        historyAudioSeconds = 0
        stopEngine()
        finishContinuation?.resume()
        finishContinuation = nil
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = PlaybackRate.normalized(rate)
        // Never mutate timePitch.overlap while the engine is rendering:
        // reconfiguring the phase vocoder mid-stream (observed on the
        // 1.5x -> 1x transition, overlap 32 -> 8) leaves it in a degraded,
        // band-limited state — output sounds like a telephone line until
        // another rate change happens to reset it. Overlap is fixed at
        // engine setup instead.
        updateAdaptivePlaybackRate()
        startPlaybackIfReady(force: inputFinished)
    }

    /// Seek playback by `offset` seconds relative to the current position.
    /// Negative values rewind into the retained history buffer; positive
    /// values fast-forward through frames scheduled but not yet played,
    /// clamped to the live generation front. Synthesis and the input side
    /// of the pipeline are untouched — only playback is repositioned.
    public func seek(by offset: TimeInterval) {
        guard canSeek, offset.isFinite, offset != 0 else { return }
        let timeline = historyFrames + inflightFrames
        let currentPosition = historyAudioSeconds
        let totalTimeline = currentPosition + inflightFrames.reduce(0) { $0 + $1.duration }
        // Clamp: never seek below zero, never seek past the frontier of
        // audio we have actually produced (streaming from the model is a
        // separate concern — playback cannot overtake generation).
        let target = min(max(currentPosition + offset, 0), totalTimeline)
        applySeek(to: target, timeline: timeline)
    }

    /// Repositions playback to an absolute `target` (in 1x audio seconds
    /// from session start) using the caller-provided ordered timeline of
    /// retained frames. Splitting this out keeps the search + rebuild path
    /// unit-testable via `resolveSeekTarget(_:in:)`.
    private func applySeek(to target: TimeInterval, timeline: [RetainedFrame]) {
        guard !timeline.isEmpty else { return }
        guard let resolved = Self.resolveSeekTarget(target, in: timeline) else { return }

        let wasPaused = paused
        // Tear the schedule down so the AVAudioPlayerNode drops any queued
        // buffers. Bumping the generation prevents stale `.dataPlayedBack`
        // callbacks from mutating history after we rebuild it below.
        scheduleGeneration += 1
        player.stop()
        queuedBuffers = 0
        queuedAudioSeconds = 0
        queuedBuffersBySegment.removeAll()
        reportedFinishedSegments.removeAll()
        waitingForAudio = false

        historyFrames = Array(timeline.prefix(resolved.timelineIndex))
        historyAudioSeconds = historyFrames.reduce(0) { $0 + $1.duration }
        inflightFrames.removeAll()

        // Rebuild the schedule: the target buffer is sliced at the intra-
        // buffer frame; subsequent frames are re-scheduled unchanged.
        let containingFrame = timeline[resolved.timelineIndex]
        if let slicedBuffer = Self.slicedBuffer(containingFrame.buffer, startingFrame: resolved.startingFrame),
           slicedBuffer.frameLength > 0 {
            let slicedDuration = Double(slicedBuffer.frameLength) / slicedBuffer.format.sampleRate
            schedule(slicedBuffer,
                     segmentIndex: containingFrame.segmentIndex,
                     duration: slicedDuration)
        }
        for frame in timeline.dropFirst(resolved.timelineIndex + 1) {
            schedule(frame.buffer,
                     segmentIndex: frame.segmentIndex,
                     duration: frame.duration)
        }

        if wasPaused {
            paused = true
            player.pause()
        } else {
            paused = false
            // Rewound audio should resume immediately; the recovery reservoir
            // threshold does not apply because we have known-good frames
            // already scheduled.
            startPlaybackIfReady(force: true)
        }

        onSeekCompleted?(containingFrame.segmentIndex, resolved.offsetWithinSegment)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, segmentIndex: Int) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        schedule(buffer, segmentIndex: segmentIndex, duration: duration)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, segmentIndex: Int, duration: TimeInterval) {
        queuedBuffers += 1
        queuedBuffersBySegment[segmentIndex, default: 0] += 1
        queuedAudioSeconds += duration
        let frame = RetainedFrame(buffer: buffer, segmentIndex: segmentIndex, duration: duration)
        inflightFrames.append(frame)
        let generation = scheduleGeneration
        updateAdaptivePlaybackRate()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.bufferFinished(segmentIndex: segmentIndex, duration: duration, generation: generation)
            }
        }
        startPlaybackIfReady(force: inputFinished)
    }

    private func bufferFinished(segmentIndex: Int, duration: TimeInterval, generation: Int) {
        // Ignore callbacks from before the last stop/seek: those buffers
        // never made it to the speaker and their bookkeeping was already
        // reset when the schedule was torn down.
        guard started, generation == scheduleGeneration else { return }
        queuedBuffers = max(0, queuedBuffers - 1)
        queuedAudioSeconds = max(0, queuedAudioSeconds - duration)
        queuedBuffersBySegment[segmentIndex] = max(0, (queuedBuffersBySegment[segmentIndex] ?? 0) - 1)
        if !inflightFrames.isEmpty {
            let played = inflightFrames.removeFirst()
            appendToHistory(played)
        }
        updateAdaptivePlaybackRate()
        onPlaybackProgress?(segmentIndex, duration)
        reportFinishedSegmentIfReady(segmentIndex)
        if Self.shouldEnterRebuffering(
            inputFinished: inputFinished,
            paused: paused,
            hasStartedPlayback: hasStartedPlayback,
            queuedBuffers: queuedBuffers,
            waitingForAudio: waitingForAudio
        ) {
            // AVAudioPlayerNode remains active after consuming its final
            // scheduled buffer. Pause it so new fragments accumulate until
            // the recovery reservoir is full instead of playing immediately.
            player.pause()
            waitingForAudio = true
            onUnderrun?()
        }
        guard inputFinished, queuedBuffers == 0 else { return }
        stopEngine()
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func appendToHistory(_ frame: RetainedFrame) {
        historyFrames.append(frame)
        historyAudioSeconds += frame.duration
        // Drop the oldest frames until we're back under the audio-seconds
        // limit. Keep at least one frame so `canSeek` remains true while
        // playback is active.
        while historyFrames.count > 1,
              historyAudioSeconds - historyFrames[0].duration >= Self.historyAudioSecondsLimit {
            historyAudioSeconds -= historyFrames.removeFirst().duration
        }
    }

    private func stopEngine() {
        player.stop()
        if engine.isRunning { engine.stop() }
        started = false
        paused = false
        hasStartedPlayback = false
        waitingForAudio = false
        queuedAudioSeconds = 0
        converter = nil
        historyFrames.removeAll()
        historyAudioSeconds = 0
        inflightFrames.removeAll()
    }

    private func startPlaybackIfReady(force: Bool) {
        guard started, !paused, queuedBuffers > 0 else { return }
        if !force,
           !hasStartedPlayback,
           waitsForInitialSegment,
           inputFinishedSegments.isEmpty,
           queuedAudioSeconds < Self.coldStartBufferedAudioSeconds(for: playbackRate)
        {
            return
        }
        let minimum = Self.minimumBufferedAudioSeconds(for: playbackRate)
        if waitingForAudio {
            let recoveryMinimum = max(minimum, Self.recoveryBufferedAudioSeconds(for: playbackRate))
            guard force || queuedAudioSeconds >= recoveryMinimum else { return }
        } else {
            guard force || hasStartedPlayback || queuedAudioSeconds >= minimum else { return }
        }
        let isFirstStart = !hasStartedPlayback
        hasStartedPlayback = true
        waitingForAudio = false
        if !player.isPlaying {
            player.play()
        }
        if isFirstStart {
            onPlaybackStarted?()
        }
    }

    static func minimumBufferedAudioSeconds(for rate: Float) -> TimeInterval {
        switch PlaybackRate.normalized(rate) {
        case ..<1.25: 0.25
        case ..<1.5: 2
        case ..<1.75: 6
        case ..<2: 7
        default: 8
        }
    }

    static func recoveryBufferedAudioSeconds(for rate: Float) -> TimeInterval {
        switch PlaybackRate.normalized(rate) {
        case ..<1.25: 4
        case ..<1.5: 5
        case ..<1.75: 8
        case ..<2: 9
        default: 10
        }
    }

    static func coldStartBufferedAudioSeconds(for rate: Float) -> TimeInterval {
        switch PlaybackRate.normalized(rate) {
        case ..<1.25: 10
        case ..<1.5: 11
        case ..<1.75: 12
        case ..<2: 13
        default: 14
        }
    }

    /// One overlap for every rate, applied once at engine setup. The old
    /// per-rate tiers (8/16/32) required live mutation on rate changes,
    /// which corrupts AVAudioUnitTimePitch mid-stream (see setPlaybackRate).
    /// 32 is the highest-quality setting; the extra CPU for one mono
    /// narration stream is negligible on Apple Silicon.
    static let fixedTimePitchOverlap: Float = 32

    static func shouldEnterRebuffering(
        inputFinished: Bool,
        paused: Bool,
        hasStartedPlayback: Bool,
        queuedBuffers: Int,
        waitingForAudio: Bool
    ) -> Bool {
        !inputFinished
            && !paused
            && hasStartedPlayback
            && queuedBuffers == 0
            && !waitingForAudio
    }

    private func updateAdaptivePlaybackRate() {
        // Keep narration at the user's selected speed. Varying this value as
        // the reservoir drained made the voice audibly slow over time. Queue
        // exhaustion is handled by a proper pause-and-rebuffer cycle instead.
        let desiredRate = playbackRate
        let difference = abs(desiredRate - effectivePlaybackRate)
        let restoringTarget = desiredRate == playbackRate && effectivePlaybackRate != playbackRate
        guard difference >= 0.05 || restoringTarget else {
            return
        }
        effectivePlaybackRate = desiredRate
        timePitch.rate = desiredRate
        onEffectivePlaybackRateChanged?(desiredRate)
    }

    private func reportFinishedSegmentIfReady(_ segmentIndex: Int) {
        guard inputFinishedSegments.contains(segmentIndex),
              queuedBuffersBySegment[segmentIndex, default: 0] == 0,
              reportedFinishedSegments.insert(segmentIndex).inserted
        else { return }
        onSegmentFinished?(segmentIndex)
    }

    private static func makeBuffer(_ chunk: PCMChunk) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(chunk.samples.count)
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(chunk.sampleRate),
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let channel = buffer.floatChannelData?[0]
        else {
            throw PCMStreamPlayerError.bufferCreationFailed
        }
        buffer.frameLength = frameCount
        chunk.samples.withUnsafeBufferPointer { samples in
            guard let source = samples.baseAddress else { return }
            channel.update(from: source, count: samples.count)
        }
        return buffer
    }

    /// Result of resolving an absolute seek target against an ordered
    /// timeline. `timelineIndex` is the frame containing the target,
    /// `startingFrame` is the intra-buffer frame offset to begin playback
    /// at, and `offsetWithinSegment` reports how far into that segment
    /// the target lands in 1x audio seconds.
    struct ResolvedSeek: Equatable {
        let timelineIndex: Int
        let startingFrame: AVAudioFramePosition
        let offsetWithinSegment: TimeInterval
    }

    /// Walks `timeline` accumulating durations until the frame that
    /// contains `target` (in 1x audio seconds from session start) is
    /// found. Public-to-the-module for direct unit testing without a
    /// real audio engine.
    static func resolveSeekTarget(_ target: TimeInterval, in timeline: [RetainedFrame]) -> ResolvedSeek? {
        guard !timeline.isEmpty else { return nil }
        let clampedTarget = max(target, 0)
        var cumulative: TimeInterval = 0
        var segmentStart: TimeInterval = 0
        var currentSegment = timeline[0].segmentIndex

        for (index, frame) in timeline.enumerated() {
            if frame.segmentIndex != currentSegment {
                currentSegment = frame.segmentIndex
                segmentStart = cumulative
            }
            let frameEnd = cumulative + frame.duration
            let isLast = index == timeline.count - 1
            if clampedTarget < frameEnd || (isLast && clampedTarget <= frameEnd) {
                let intraOffset = max(0, clampedTarget - cumulative)
                let sampleRate = frame.buffer.format.sampleRate
                let rawFrame = AVAudioFramePosition((intraOffset * sampleRate).rounded())
                let boundedFrame = min(max(rawFrame, 0), AVAudioFramePosition(frame.buffer.frameLength))
                return ResolvedSeek(
                    timelineIndex: index,
                    startingFrame: boundedFrame,
                    offsetWithinSegment: max(0, clampedTarget - segmentStart)
                )
            }
            cumulative = frameEnd
        }
        // Target beyond the timeline: resolve at the tail so the caller
        // can no-op or continue past the end cleanly.
        let last = timeline[timeline.count - 1]
        return ResolvedSeek(
            timelineIndex: timeline.count - 1,
            startingFrame: AVAudioFramePosition(last.buffer.frameLength),
            offsetWithinSegment: max(0, cumulative - segmentStart)
        )
    }

    /// Returns a new PCM buffer containing the samples of `source` from
    /// `startingFrame` to its end. Returns `nil` if the source format is
    /// unsupported for slicing or the offset is past the buffer end.
    static func slicedBuffer(_ source: AVAudioPCMBuffer, startingFrame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard source.format.commonFormat == .pcmFormatFloat32 else { return nil }
        let totalFrames = AVAudioFramePosition(source.frameLength)
        guard startingFrame >= 0, startingFrame <= totalFrames else { return nil }
        let remaining = AVAudioFrameCount(totalFrames - startingFrame)
        guard remaining > 0 else { return nil }
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: remaining),
              let sourceData = source.floatChannelData,
              let destinationData = destination.floatChannelData
        else { return nil }
        destination.frameLength = remaining
        for channel in 0..<Int(source.format.channelCount) {
            let sourcePointer = sourceData[channel].advanced(by: Int(startingFrame))
            let destinationPointer = destinationData[channel]
            destinationPointer.update(from: sourcePointer, count: Int(remaining))
        }
        return destination
    }

    // Test hooks: SFNativeVoiceTests drives the seek math and history
    // bookkeeping directly without a running audio engine. Kept internal
    // so external callers still use the public surface only.
    func testing_appendRetainedFrame(sampleCount: AVAudioFrameCount, sampleRate: Double, segmentIndex: Int) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount) else { return }
        buffer.frameLength = sampleCount
        let duration = Double(sampleCount) / sampleRate
        appendToHistory(RetainedFrame(buffer: buffer, segmentIndex: segmentIndex, duration: duration))
    }

    var testing_historyAudioSeconds: TimeInterval { historyAudioSeconds }
    var testing_historyFrameCount: Int { historyFrames.count }
}

public enum PCMStreamPlayerError: Error, LocalizedError, Equatable {
    case audioOutputUnavailable
    case notStarted
    case bufferCreationFailed

    public var errorDescription: String? {
        switch self {
        case .audioOutputUnavailable:
            return "No usable macOS audio output is available."
        case .notStarted:
            return "Start the PCM stream player before enqueueing audio."
        case .bufferCreationFailed:
            return "Could not create a PCM audio buffer."
        }
    }
}
