import Foundation
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS

public struct NativeSpeechRequest: Sendable, Equatable {
    public var text: String
    public var voice: String?
    public var language: String?
    public var streamingInterval: Double

    public init(
        text: String,
        voice: String? = nil,
        language: String? = "English",
        streamingInterval: Double = 0.32
    ) {
        self.text = text
        self.voice = voice
        self.language = language
        self.streamingInterval = streamingInterval
    }
}

public struct PCMChunk: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
}

public struct NativeGenerationStatistics: Sendable, Equatable {
    public let promptTokenCount: Int
    public let generationTokenCount: Int
    public let prefillSeconds: TimeInterval
    public let generationSeconds: TimeInterval
    public let tokensPerSecond: Double
    public let peakMemoryGB: Double

    init(_ info: AudioGenerationInfo) {
        promptTokenCount = info.promptTokenCount
        generationTokenCount = info.generationTokenCount
        prefillSeconds = info.prefillTime
        generationSeconds = info.generateTime
        tokensPerSecond = info.tokensPerSecond
        peakMemoryGB = info.peakMemoryUsage
    }
}

public enum NativeSpeechEvent: Sendable, Equatable {
    case audio(PCMChunk)
    case statistics(NativeGenerationStatistics)
}

/// MLX's model protocol is not Sendable, although the Qwen implementation is
/// internally synchronized and declares unchecked Sendable conformance. Keep
/// the model and its reference conditioning together while generation runs on
/// a user-initiated task instead of inheriting the app's MainActor.
private struct NativeGenerationJob: @unchecked Sendable {
    let model: any SpeechGenerationModel
    let referenceConditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning?
    let request: NativeSpeechRequest

    var sampleRate: Int { model.sampleRate }

    func makeStream() throws -> AsyncThrowingStream<AudioGeneration, Error> {
        if let referenceConditioning {
            guard let qwenModel = model as? Qwen3TTSModel else {
                throw NativeMLXProviderError.unsupportedVoiceProfileModel("non-Qwen model")
            }
            return qwenModel.generateStream(
                text: request.text,
                conditioning: referenceConditioning,
                generationParameters: qwenModel.defaultGenerationParameters,
                streamingInterval: request.streamingInterval
            )
        }
        return model.generateStream(
            text: request.text,
            voice: request.voice,
            refAudio: nil,
            refText: nil,
            language: request.language,
            generationParameters: model.defaultGenerationParameters,
            streamingInterval: request.streamingInterval
        )
    }
}

/// Thin, deliberately isolated adapter around mlx-audio-swift. The app does
/// not depend on this spike target; promoting it later only requires swapping
/// the existing local provider at the composition root.
@MainActor
public final class NativeMLXProvider {
    nonisolated public static let defaultModelID = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
    nonisolated public static let baseVoiceModelID = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
    nonisolated public static let supportedPresetVoices = [
        "Serena", "Vivian", "Ono_Anna", "Sohee", "Ryan", "Aiden", "Uncle_Fu", "Dylan", "Eric",
    ]
    public let modelID: String
    public let memoryBudget: NativeMemoryBudget
    private var model: (any SpeechGenerationModel)?
    private let voiceProfile: NativeVoiceProfile?
    private var referenceConditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning?
    private var referenceConditioningLanguage: String?
    private var referenceAudio: MLXArray?

    public init(
        modelID: String = NativeMLXProvider.defaultModelID,
        voiceProfile: NativeVoiceProfile? = nil,
        memoryBudget: NativeMemoryBudget = .current
    ) {
        self.modelID = modelID
        self.voiceProfile = voiceProfile
        self.memoryBudget = memoryBudget
    }

    public var isLoaded: Bool { model != nil }
    public var sampleRate: Int? { model?.sampleRate }
    public var hasVoiceProfile: Bool { voiceProfile?.isUsable == true }

    public var isDownloaded: Bool {
        Self.isModelDownloaded(modelID: modelID)
    }

    public static var activeMemoryGB: Double {
        Double(Memory.activeMemory) / 1_000_000_000
    }

    public static var cacheMemoryGB: Double {
        Double(Memory.cacheMemory) / 1_000_000_000
    }

    /// Downloads the snapshot with progress before constructing the model.
    /// Keeping this separate from weight loading gives the UI a meaningful
    /// determinate phase instead of one long indeterminate spinner.
    @discardableResult
    public func prepare(
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> TimeInterval {
        guard model == nil else {
            progressHandler(1)
            return 0
        }

        try validateVoiceProfileRequirement()

        guard let repoID = Repo.ID(rawValue: modelID) else {
            throw NativeMLXProviderError.invalidModelID(modelID)
        }
        try validateHardwareRequirement()

        if !isDownloaded {
            let available = try Self.availableCapacity()
            guard available >= NativeMemoryBudget.minimumFreeDiskBytes else {
                throw NativeMLXProviderError.insufficientDiskSpace(
                    requiredBytes: NativeMemoryBudget.minimumFreeDiskBytes,
                    availableBytes: available
                )
            }
        }

        let cache = HubCache.default
        let client = HubClient(cache: cache)
        _ = try await ModelUtils.resolveOrDownloadModel(
            client: client,
            cache: cache,
            repoID: repoID,
            requiredExtension: "safetensors"
        ) { progress in
            let total = max(progress.totalUnitCount, 1)
            progressHandler(min(max(Double(progress.completedUnitCount) / Double(total), 0), 1))
        }
        try Task.checkCancellation()
        progressHandler(1)
        let loadSeconds = try await load()
        try Task.checkCancellation()
        return loadSeconds
    }

    /// Returns model-load time. The first call includes any Hugging Face
    /// download; subsequent calls are a no-op so generation can be measured
    /// independently from installation cost.
    @discardableResult
    public func load() async throws -> TimeInterval {
        guard model == nil else { return 0 }
        try validateVoiceProfileRequirement()
        try validateHardwareRequirement()
        Memory.cacheLimit = memoryBudget.cacheLimitBytes
        let start = ContinuousClock.now
        let loadedModel = try await TTS.loadModel(modelRepo: modelID)
        model = loadedModel
        do {
            try prepareReferenceConditioningIfNeeded()
        } catch {
            model = nil
            referenceConditioning = nil
            referenceConditioningLanguage = nil
            referenceAudio = nil
            Memory.clearCache()
            throw error
        }
        return Self.seconds(since: start)
    }

    public func unload() {
        model = nil
        referenceConditioning = nil
        referenceConditioningLanguage = nil
        referenceAudio = nil
        Memory.clearCache()
    }

    public func stream(_ request: NativeSpeechRequest) throws -> AsyncThrowingStream<NativeSpeechEvent, Error> {
        guard let model else {
            throw NativeMLXProviderError.modelNotLoaded
        }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeMLXProviderError.emptyText
        }

        let job = NativeGenerationJob(
            model: model,
            referenceConditioning: try referenceConditioning(for: request.language),
            request: request
        )

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let upstream = try job.makeStream()
                    for try await event in upstream {
                        try Task.checkCancellation()
                        switch event {
                        case .audio(let audio):
                            continuation.yield(.audio(PCMChunk(
                                samples: audio.asArray(Float.self),
                                sampleRate: job.sampleRate
                            )))
                        case .info(let info):
                            continuation.yield(.statistics(NativeGenerationStatistics(info)))
                        case .token:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private var requiresVoiceProfile: Bool {
        modelID.localizedCaseInsensitiveContains("Qwen3-TTS")
            && modelID.localizedCaseInsensitiveContains("-Base")
    }

    private func validateVoiceProfileRequirement() throws {
        guard requiresVoiceProfile else { return }
        guard voiceProfile?.isUsable == true else {
            throw NativeMLXProviderError.voiceProfileRequired(modelID)
        }
    }

    private func validateHardwareRequirement() throws {
        guard memoryBudget.supportsNativeMLX else {
            throw NativeMLXProviderError.unsupportedPhysicalMemory(
                requiredBytes: NativeMemoryBudget.minimumSupportedMemoryBytes,
                availableBytes: memoryBudget.physicalMemoryBytes
            )
        }
    }

    private func prepareReferenceConditioningIfNeeded() throws {
        guard let voiceProfile else { return }
        guard voiceProfile.isUsable else {
            throw NativeMLXProviderError.voiceProfileRequired(modelID)
        }
        guard let qwenModel = model as? Qwen3TTSModel else {
            throw NativeMLXProviderError.unsupportedVoiceProfileModel(modelID)
        }
        let (_, referenceAudio) = try loadAudioArray(
            from: voiceProfile.referenceAudioURL,
            sampleRate: qwenModel.sampleRate
        )
        self.referenceAudio = referenceAudio
        referenceConditioning = try qwenModel.prepareReferenceConditioning(
            refAudio: referenceAudio,
            refText: voiceProfile.referenceText,
            language: voiceProfile.language
        )
        referenceConditioningLanguage = voiceProfile.language.lowercased()
    }

    private func referenceConditioning(
        for language: String?
    ) throws -> Qwen3TTSModel.Qwen3TTSReferenceConditioning? {
        guard let voiceProfile, let referenceAudio else { return referenceConditioning }
        let requestedLanguage = (language ?? voiceProfile.language).lowercased()
        if requestedLanguage == referenceConditioningLanguage {
            return referenceConditioning
        }
        guard let qwenModel = model as? Qwen3TTSModel else {
            throw NativeMLXProviderError.unsupportedVoiceProfileModel(modelID)
        }
        let conditioning = try qwenModel.prepareReferenceConditioning(
            refAudio: referenceAudio,
            refText: voiceProfile.referenceText,
            language: requestedLanguage
        )
        referenceConditioning = conditioning
        referenceConditioningLanguage = requestedLanguage
        return conditioning
    }


    private nonisolated static func modelDirectory(modelID: String) -> URL {
        let modelSubdirectory = modelID.replacingOccurrences(of: "/", with: "_")
        return HubCache.default.cacheDirectory
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(modelSubdirectory, isDirectory: true)
    }

    private nonisolated static func isModelDownloaded(modelID: String) -> Bool {
        let directory = modelDirectory(modelID: modelID)
        let config = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: config.path),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return false }
        return files.contains { url in
            guard url.pathExtension == "safetensors" else { return false }
            return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    private nonisolated static func availableCapacity() throws -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

public enum NativeMLXProviderError: Error, LocalizedError, Equatable {
    case modelNotLoaded
    case emptyText
    case invalidModelID(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case unsupportedPhysicalMemory(requiredBytes: UInt64, availableBytes: UInt64)
    case voiceProfileRequired(String)
    case unsupportedVoiceProfileModel(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Load the native MLX model before requesting speech."
        case .emptyText:
            return "Speech text cannot be empty."
        case .invalidModelID(let modelID):
            return "Invalid Hugging Face model ID: \(modelID)"
        case .insufficientDiskSpace(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Native voice needs at least \(formatter.string(fromByteCount: required)) free; \(formatter.string(fromByteCount: available)) is available."
        case .unsupportedPhysicalMemory(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .memory
            return "Native MLX needs at least \(formatter.string(fromByteCount: Int64(required))) of unified memory; this Mac has \(formatter.string(fromByteCount: Int64(available))). Use the Kokoro backend instead."
        case .voiceProfileRequired(let modelID):
            return "\(modelID) needs an installed native voice profile. Create the American voice first."
        case .unsupportedVoiceProfileModel(let modelID):
            return "\(modelID) does not support Qwen reference voice conditioning."
        }
    }
}
