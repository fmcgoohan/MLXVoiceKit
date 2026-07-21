@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import MLXVoiceCore

@MainActor
private func makeFrame(seconds: TimeInterval, segmentIndex: Int, sampleRate: Double = 24_000) -> PCMStreamPlayer.RetainedFrame {
    let frameCount = AVAudioFrameCount((seconds * sampleRate).rounded())
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    // Fill with a distinguishable value per segment so slicing sanity checks
    // aren't misled by all-zero buffers.
    if let channel = buffer.floatChannelData?[0] {
        for index in 0..<Int(frameCount) {
            channel[index] = Float(segmentIndex) + 0.001 * Float(index % 100)
        }
    }
    return PCMStreamPlayer.RetainedFrame(
        buffer: buffer,
        segmentIndex: segmentIndex,
        duration: Double(frameCount) / sampleRate
    )
}

@MainActor
@Test func pcmSeekResolvesInsideFirstFrame() {
    let timeline = [
        makeFrame(seconds: 2, segmentIndex: 0),
        makeFrame(seconds: 3, segmentIndex: 0),
        makeFrame(seconds: 4, segmentIndex: 1),
    ]
    let resolved = try! #require(PCMStreamPlayer.resolveSeekTarget(0.5, in: timeline))
    #expect(resolved.timelineIndex == 0)
    #expect(resolved.offsetWithinSegment == 0.5)
}

@MainActor
@Test func pcmSeekResolvesAtFrameBoundary() {
    let timeline = [
        makeFrame(seconds: 2, segmentIndex: 0),
        makeFrame(seconds: 3, segmentIndex: 0),
        makeFrame(seconds: 4, segmentIndex: 1),
    ]
    // 2.0s lands exactly at the boundary between the first and second frames.
    // The resolver treats `end` as exclusive except for the final frame, so a
    // value of 2.0 belongs to the second frame at intra-frame offset 0.
    let resolved = try! #require(PCMStreamPlayer.resolveSeekTarget(2.0, in: timeline))
    #expect(resolved.timelineIndex == 1)
    #expect(resolved.startingFrame == 0)
}

@MainActor
@Test func pcmSeekResolvesAcrossSegmentBoundary() {
    let timeline = [
        makeFrame(seconds: 2, segmentIndex: 0),
        makeFrame(seconds: 3, segmentIndex: 0),
        makeFrame(seconds: 4, segmentIndex: 1),
    ]
    // Segment 0 spans 0-5s, segment 1 spans 5-9s. Target 6.5s falls 1.5s into
    // segment 1's single frame.
    let resolved = try! #require(PCMStreamPlayer.resolveSeekTarget(6.5, in: timeline))
    #expect(resolved.timelineIndex == 2)
    #expect(abs(resolved.offsetWithinSegment - 1.5) < 0.001)
}

@MainActor
@Test func pcmSeekClampsPastTail() {
    let timeline = [
        makeFrame(seconds: 2, segmentIndex: 0),
        makeFrame(seconds: 3, segmentIndex: 1),
    ]
    // Beyond the timeline: resolver returns the tail so the caller can
    // no-op cleanly rather than crashing.
    let resolved = try! #require(PCMStreamPlayer.resolveSeekTarget(999, in: timeline))
    #expect(resolved.timelineIndex == 1)
    // Starting frame at the very end so the sliced buffer would be empty
    // and the caller effectively no-ops the reschedule.
    let last = timeline.last!.buffer
    #expect(resolved.startingFrame == AVAudioFramePosition(last.frameLength))
}

@MainActor
@Test func pcmSeekReturnsNilForEmptyTimeline() {
    #expect(PCMStreamPlayer.resolveSeekTarget(0, in: []) == nil)
}

@MainActor
@Test func pcmSlicedBufferReturnsRemainingFrames() {
    let source = makeFrame(seconds: 1, segmentIndex: 0).buffer
    let sliced = try! #require(PCMStreamPlayer.slicedBuffer(source, startingFrame: 8_000))
    // Source has 24 000 frames at 24 kHz; slicing at 8 000 leaves 16 000.
    #expect(sliced.frameLength == 16_000)
    // First sample of the slice must match source[8_000] so we know the
    // slice reads from the correct offset rather than the origin.
    #expect(sliced.floatChannelData?[0][0] == source.floatChannelData?[0][8_000])
}

@MainActor
@Test func pcmSlicedBufferReturnsNilPastEnd() {
    let source = makeFrame(seconds: 1, segmentIndex: 0).buffer
    #expect(PCMStreamPlayer.slicedBuffer(source, startingFrame: AVAudioFramePosition(source.frameLength)) == nil)
}

@MainActor
@Test func pcmHistoryRespectsAudioSecondsLimit() {
    let player = PCMStreamPlayer()
    // Push enough frames to exceed the 60 s bound. Each is 5 s long so 20
    // frames = 100 s of retained audio pre-eviction.
    for index in 0..<20 {
        player.testing_appendRetainedFrame(sampleCount: 24_000 * 5, sampleRate: 24_000, segmentIndex: index / 4)
    }
    // Once trimmed, the bound may be up to (limit - shortestFrame + longestFrame)
    // in the worst case, but for uniform frames it should sit at or below
    // 60 s while retaining at least one frame.
    #expect(player.testing_historyAudioSeconds <= 60)
    #expect(player.testing_historyFrameCount >= 1)
    #expect(player.testing_historyFrameCount <= 13) // 60 s / 5 s + slack for boundary retention
}
