import Foundation
import MLXAudioCore

@MainActor
public final class NativeVoiceDesigner {
    nonisolated public static let defaultModelID = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
    nonisolated public static let defaultDesignPrompt = """
        A warm, confident American woman in her early thirties with a neutral General American broadcast accent. Crisp consonants, natural pacing, clear enunciation, and no strong regional coloring. Calm, friendly, and suitable for long-form narration.
        """
    nonisolated public static let calibrationText = """
        Good morning. Today is Thursday, July fifteenth. The project begins at nine thirty, and the estimated cost is twenty-four dollars. Could you review the final report before lunch? Clear communication makes complicated ideas easier to understand.
        """

    public let modelID: String
    private let provider: NativeMLXProvider

    public init(modelID: String = NativeVoiceDesigner.defaultModelID) {
        self.modelID = modelID
        self.provider = NativeMLXProvider(modelID: modelID)
    }

    public func generateCandidate(
        designPrompt: String = NativeVoiceDesigner.defaultDesignPrompt,
        referenceText: String = NativeVoiceDesigner.calibrationText,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> NativeVoiceCandidate {
        _ = try await provider.prepare(progressHandler: progressHandler)

        var samples: [Float] = []
        var sampleRate: Int?
        let events = try provider.stream(NativeSpeechRequest(
            text: referenceText,
            voice: designPrompt,
            language: "English"
        ))
        for try await event in events {
            try Task.checkCancellation()
            guard case .audio(let chunk) = event else { continue }
            if let sampleRate, sampleRate != chunk.sampleRate {
                throw NativeVoiceDesignerError.inconsistentSampleRate
            }
            sampleRate = chunk.sampleRate
            samples.append(contentsOf: chunk.samples)
        }

        guard let sampleRate, !samples.isEmpty else {
            throw NativeVoiceDesignerError.emptyAudio
        }

        let candidateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXVoiceCandidates", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
        let audioURL = candidateDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try AudioUtils.writeWavFile(samples: samples, sampleRate: sampleRate, fileURL: audioURL)

        return NativeVoiceCandidate(
            audioURL: audioURL,
            referenceText: referenceText,
            designPrompt: designPrompt,
            sourceModelID: modelID
        )
    }

    public func unload() {
        provider.unload()
    }
}

public enum NativeVoiceDesignerError: Error, LocalizedError, Equatable {
    case emptyAudio
    case inconsistentSampleRate

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "VoiceDesign completed without producing audio."
        case .inconsistentSampleRate:
            return "VoiceDesign emitted audio with inconsistent sample rates."
        }
    }
}
