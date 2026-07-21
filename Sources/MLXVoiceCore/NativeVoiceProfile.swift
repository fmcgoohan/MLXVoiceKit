import Foundation

public struct NativeVoiceProfile: Codable, Sendable, Equatable {
    public let name: String
    public let language: String
    public let referenceAudioPath: String
    public let referenceText: String
    public let designPrompt: String
    public let sourceModelID: String
    public let createdAt: Date

    public init(
        name: String,
        language: String,
        referenceAudioPath: String,
        referenceText: String,
        designPrompt: String,
        sourceModelID: String,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.language = language
        self.referenceAudioPath = referenceAudioPath
        self.referenceText = referenceText
        self.designPrompt = designPrompt
        self.sourceModelID = sourceModelID
        self.createdAt = createdAt
    }

    public var referenceAudioURL: URL {
        URL(fileURLWithPath: referenceAudioPath)
    }

    public var isUsable: Bool {
        !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && FileManager.default.fileExists(atPath: referenceAudioPath)
    }
}

public struct NativeVoiceCandidate: Sendable, Equatable {
    public let audioURL: URL
    public let referenceText: String
    public let designPrompt: String
    public let sourceModelID: String

    public init(
        audioURL: URL,
        referenceText: String,
        designPrompt: String,
        sourceModelID: String
    ) {
        self.audioURL = audioURL
        self.referenceText = referenceText
        self.designPrompt = designPrompt
        self.sourceModelID = sourceModelID
    }
}

public enum NativeVoiceProfileStore {
    /// Application-Support subdirectory the installed voice profile lives under.
    /// Override once at launch to brand it for your app (e.g. `"SpeakFlowLocal"`)
    /// so existing installs keep resolving; defaults to a neutral value.
    public nonisolated(unsafe) static var applicationSupportSubdirectory = "MLXVoiceKit"

    public static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportSubdirectory, isDirectory: true)
            .appendingPathComponent("voices", isDirectory: true)
            .appendingPathComponent("american-narrator", isDirectory: true)
    }

    public static var defaultProfileURL: URL {
        defaultDirectoryURL.appendingPathComponent("profile.json")
    }

    public static func load(from profileURL: URL) throws -> NativeVoiceProfile {
        let data = try Data(contentsOf: profileURL)
        let profile = try JSONDecoder().decode(NativeVoiceProfile.self, from: data)
        guard profile.isUsable else { throw NativeVoiceProfileError.unusableProfile }
        return profile
    }

    @discardableResult
    public static func install(
        _ candidate: NativeVoiceCandidate,
        name: String = "American Narrator",
        directoryURL: URL = defaultDirectoryURL,
        createdAt: Date = Date()
    ) throws -> (profile: NativeVoiceProfile, profileURL: URL) {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let referenceURL = directoryURL.appendingPathComponent("reference.wav")
        let candidateData = try Data(contentsOf: candidate.audioURL)
        try candidateData.write(to: referenceURL, options: .atomic)

        let profile = NativeVoiceProfile(
            name: name,
            language: "English",
            referenceAudioPath: referenceURL.path,
            referenceText: candidate.referenceText,
            designPrompt: candidate.designPrompt,
            sourceModelID: candidate.sourceModelID,
            createdAt: createdAt
        )
        let profileURL = directoryURL.appendingPathComponent("profile.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: profileURL, options: .atomic)
        return (profile, profileURL)
    }
}

public enum NativeVoiceProfileError: Error, LocalizedError, Equatable {
    case unusableProfile

    public var errorDescription: String? {
        switch self {
        case .unusableProfile:
            return "The native voice profile is missing its reference audio or transcript."
        }
    }
}
