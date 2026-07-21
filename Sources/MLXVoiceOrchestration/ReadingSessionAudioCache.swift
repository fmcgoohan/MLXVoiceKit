@preconcurrency import AVFAudio
import Foundation
import MLXVoiceCore
import SwiftReadingSession

/// Temporary, normal-speed audio retained per synthesis request. The cache is
/// deliberately shaped like the future archive package, but remains a cache:
/// SpeakFlow may remove it until the user explicitly keeps an item.
public final class ReadingSessionAudioCache: @unchecked Sendable {
    public let directoryURL: URL
    private let writeQueue = DispatchQueue(label: "com.speakflow.session-audio-cache", qos: .utility)
    private var writers: [Int: (sampleRate: Int, file: AVAudioFile)] = [:]
    private var writeError: Error?

    public init(sessionID: UUID, baseDirectory: URL? = nil) throws {
        let root = baseDirectory ?? ReadingSessionLocations.recentSessionsDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.pruneExpiredSessions(in: root, excluding: sessionID)
        directoryURL = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Copies PCM persistence off the generation actor. The serial queue keeps
    /// every write and segment close in emission order without delaying live
    /// playback or the next MLX event.
    public func append(
        _ chunk: PCMChunk,
        segmentIndex: Int,
        onFailure: (@Sendable (Error) -> Void)? = nil
    ) {
        guard !chunk.samples.isEmpty else { return }
        writeQueue.async { [self] in
            guard writeError == nil else { return }
            do {
                try appendSynchronously(chunk, segmentIndex: segmentIndex)
            } catch {
                writeError = error
                onFailure?(error)
            }
        }
    }

    private func appendSynchronously(_ chunk: PCMChunk, segmentIndex: Int) throws {
        let writer: AVAudioFile
        if let existing = writers[segmentIndex] {
            guard existing.sampleRate == chunk.sampleRate else {
                throw ReadingSessionAudioCacheError.sampleRateChanged
            }
            writer = existing.file
        } else {
            let format = try Self.format(sampleRate: chunk.sampleRate)
            let url = audioURL(segmentIndex: segmentIndex)
            writer = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            writers[segmentIndex] = (chunk.sampleRate, writer)
        }
        try writer.write(from: try Self.buffer(for: chunk))
    }

    public func finishSegment(_ segmentIndex: Int) {
        writeQueue.async { [self] in
            writers.removeValue(forKey: segmentIndex)
        }
    }

    public func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                if let writeError {
                    continuation.resume(throwing: writeError)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func persist(_ session: ReadingSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(
            to: directoryURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    public func audioURL(segmentIndex: Int) -> URL {
        directoryURL.appendingPathComponent(String(format: "%04d.caf", segmentIndex))
    }

    private static func pruneExpiredSessions(in root: URL, excluding sessionID: UUID) {
        let expiration = Date().addingTimeInterval(-24 * 60 * 60)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children where child.lastPathComponent != sessionID.uuidString {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < expiration
            else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    private static func format(sampleRate: Int) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw ReadingSessionAudioCacheError.bufferCreationFailed
        }
        return format
    }

    private static func buffer(for chunk: PCMChunk) throws -> AVAudioPCMBuffer {
        let format = try format(sampleRate: chunk.sampleRate)
        let frameCount = AVAudioFrameCount(chunk.samples.count)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let channel = buffer.floatChannelData?[0]
        else {
            throw ReadingSessionAudioCacheError.bufferCreationFailed
        }
        buffer.frameLength = frameCount
        chunk.samples.withUnsafeBufferPointer { samples in
            guard let source = samples.baseAddress else { return }
            channel.update(from: source, count: samples.count)
        }
        return buffer
    }
}

public enum ReadingSessionAudioCacheError: Error, Equatable {
    case sampleRateChanged
    case bufferCreationFailed
}
