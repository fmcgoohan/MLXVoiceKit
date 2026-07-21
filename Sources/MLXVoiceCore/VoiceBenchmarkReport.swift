import Foundation
import SwiftSpeechKit

public struct VoiceBenchmarkResult: Codable, Sendable, Equatable {
    public let backend: String
    public let model: String
    public let iteration: Int
    public let modelLoadSeconds: Double?
    public let timeToFirstAudioSeconds: Double?
    public let generationSeconds: Double?
    public let audioSeconds: Double?
    public let realtimeMultiple: Double?
    public let audioChunkCount: Int?
    public let characterCount: Int?
    public let requestCount: Int?
    public let tokensPerSecond: Double?
    public let peakMemoryGB: Double?
    public let targetPlaybackRate: Double?
    public let playbackSeconds: Double?
    public let deliveredPlaybackMultiple: Double?
    public let adaptivePlaybackSeconds: Double?
    public let minimumEffectivePlaybackRate: Double?
    public let underrunCount: Int?
    public let error: String?

    public init(
        backend: String,
        model: String,
        iteration: Int,
        modelLoadSeconds: Double? = nil,
        timeToFirstAudioSeconds: Double? = nil,
        generationSeconds: Double? = nil,
        audioSeconds: Double? = nil,
        realtimeMultiple: Double? = nil,
        audioChunkCount: Int? = nil,
        characterCount: Int? = nil,
        requestCount: Int? = nil,
        tokensPerSecond: Double? = nil,
        peakMemoryGB: Double? = nil,
        targetPlaybackRate: Double? = nil,
        playbackSeconds: Double? = nil,
        deliveredPlaybackMultiple: Double? = nil,
        adaptivePlaybackSeconds: Double? = nil,
        minimumEffectivePlaybackRate: Double? = nil,
        underrunCount: Int? = nil,
        error: String? = nil
    ) {
        self.backend = backend
        self.model = model
        self.iteration = iteration
        self.modelLoadSeconds = modelLoadSeconds
        self.timeToFirstAudioSeconds = timeToFirstAudioSeconds
        self.generationSeconds = generationSeconds
        self.audioSeconds = audioSeconds
        self.realtimeMultiple = realtimeMultiple
        self.audioChunkCount = audioChunkCount
        self.characterCount = characterCount
        self.requestCount = requestCount
        self.tokensPerSecond = tokensPerSecond
        self.peakMemoryGB = peakMemoryGB
        self.targetPlaybackRate = targetPlaybackRate
        self.playbackSeconds = playbackSeconds
        self.deliveredPlaybackMultiple = deliveredPlaybackMultiple
        self.adaptivePlaybackSeconds = adaptivePlaybackSeconds
        self.minimumEffectivePlaybackRate = minimumEffectivePlaybackRate
        self.underrunCount = underrunCount
        self.error = error
    }
}

public struct NativeBenchmarkDiagnostics: Codable, Sendable, Equatable {
    public let physicalMemoryGB: Double
    public let hardwareTier: NativeHardwareTier
    public let cacheLimitGB: Double
    public let cancellationAfterSeconds: Double?
    public let cancellationResponseSeconds: Double?
    public let cancellationSucceeded: Bool?
    public let activeMemoryBeforeLoadGB: Double
    public let activeMemoryAfterLoadGB: Double
    public let activeMemoryAfterUnloadGB: Double
    public let cacheMemoryAfterUnloadGB: Double

    public init(
        physicalMemoryGB: Double,
        hardwareTier: NativeHardwareTier,
        cacheLimitGB: Double,
        cancellationAfterSeconds: Double? = nil,
        cancellationResponseSeconds: Double? = nil,
        cancellationSucceeded: Bool? = nil,
        activeMemoryBeforeLoadGB: Double,
        activeMemoryAfterLoadGB: Double,
        activeMemoryAfterUnloadGB: Double,
        cacheMemoryAfterUnloadGB: Double
    ) {
        self.physicalMemoryGB = physicalMemoryGB
        self.hardwareTier = hardwareTier
        self.cacheLimitGB = cacheLimitGB
        self.cancellationAfterSeconds = cancellationAfterSeconds
        self.cancellationResponseSeconds = cancellationResponseSeconds
        self.cancellationSucceeded = cancellationSucceeded
        self.activeMemoryBeforeLoadGB = activeMemoryBeforeLoadGB
        self.activeMemoryAfterLoadGB = activeMemoryAfterLoadGB
        self.activeMemoryAfterUnloadGB = activeMemoryAfterUnloadGB
        self.cacheMemoryAfterUnloadGB = cacheMemoryAfterUnloadGB
    }
}

public struct VoiceBenchmarkReport: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let text: String
    public let results: [VoiceBenchmarkResult]
    public let nativeDiagnostics: NativeBenchmarkDiagnostics?

    public init(
        generatedAt: Date = Date(),
        text: String,
        results: [VoiceBenchmarkResult],
        nativeDiagnostics: NativeBenchmarkDiagnostics? = nil
    ) {
        self.generatedAt = generatedAt
        self.text = text
        self.results = results
        self.nativeDiagnostics = nativeDiagnostics
    }

    public var acceptanceFailures: [String] {
        acceptanceChecks.compactMap { label, passed in passed ? nil : label }
    }

    public func markdown() -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "# SpeakFlow Voice Benchmark",
            "",
            "Generated: \(formatter.string(from: generatedAt))",
            "",
            "Workload: \(text.count) characters",
            "",
            "| Backend | Model | Run | Chars | Requests | Load | First audio | Generate | Audio | Realtime | PCM chunks | Tokens/s | Peak GB | Status |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
        ]
        lines.append(contentsOf: results.map(Self.markdownRow))
        lines.append("")
        lines.append("Realtime is audio duration divided by generation time; values above 1.0x are faster than realtime.")
        appendPlaybackTable(to: &lines)
        appendNativeDiagnostics(to: &lines)
        appendAcceptanceChecks(to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func markdownRow(_ result: VoiceBenchmarkResult) -> String {
        let status: String
        if let error = result.error {
            status = "failed: \(error.replacingOccurrences(of: "|", with: "/"))"
        } else {
            status = "ok"
        }
        var columns: [String] = []
        columns.append(result.backend)
        columns.append(result.model)
        columns.append(String(result.iteration))
        columns.append(result.characterCount.map(String.init) ?? "-")
        columns.append(result.requestCount.map(String.init) ?? "-")
        columns.append(format(result.modelLoadSeconds))
        columns.append(format(result.timeToFirstAudioSeconds))
        columns.append(format(result.generationSeconds))
        columns.append(format(result.audioSeconds))
        columns.append(result.realtimeMultiple.map { String(format: "%.2fx", $0) } ?? "-")
        columns.append(result.audioChunkCount.map(String.init) ?? "-")
        columns.append(format(result.tokensPerSecond))
        columns.append(format(result.peakMemoryGB))
        columns.append(status)
        return columns.joined(separator: " | ").withTableEdges()
    }

    private func appendPlaybackTable(to lines: inout [String]) {
        let playbackResults = results.filter { $0.targetPlaybackRate != nil }
        guard !playbackResults.isEmpty else { return }
        lines += [
            "",
            "## Live PCM playback",
            "",
            "| Backend | Run | Target | Playback wall | Delivered | Adaptive time | Minimum rate | Underruns |",
            "|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
        lines.append(contentsOf: playbackResults.map { result in
            [
                result.backend,
                String(result.iteration),
                Self.formatRate(result.targetPlaybackRate),
                Self.format(result.playbackSeconds),
                Self.formatRate(result.deliveredPlaybackMultiple),
                Self.format(result.adaptivePlaybackSeconds),
                Self.formatRate(result.minimumEffectivePlaybackRate),
                result.underrunCount.map(String.init) ?? "-",
            ].joined(separator: " | ").withTableEdges()
        })
        lines.append("")
        lines.append("Delivered speed includes any PCM starvation gaps.")
    }

    private func appendNativeDiagnostics(to lines: inout [String]) {
        guard let diagnostics = nativeDiagnostics else { return }
        lines += [
            "",
            "## Native lifecycle",
            "",
            "- Physical memory: \(Self.format(diagnostics.physicalMemoryGB)) GB (\(diagnostics.hardwareTier.displayName))",
            "- MLX cache limit: \(Self.format(diagnostics.cacheLimitGB)) GB",
            "- Active MLX memory before load: \(Self.format(diagnostics.activeMemoryBeforeLoadGB)) GB",
            "- Active MLX memory after load: \(Self.format(diagnostics.activeMemoryAfterLoadGB)) GB",
            "- Active MLX memory after unload: \(Self.format(diagnostics.activeMemoryAfterUnloadGB)) GB",
            "- Cached MLX memory after unload: \(Self.format(diagnostics.cacheMemoryAfterUnloadGB)) GB",
        ]
        if let after = diagnostics.cancellationAfterSeconds,
           let response = diagnostics.cancellationResponseSeconds,
           let succeeded = diagnostics.cancellationSucceeded
        {
            lines.append("- Cancellation after \(Self.format(after))s: \(succeeded ? "passed" : "failed") in \(Self.format(response))s")
        }
    }

    private func appendAcceptanceChecks(to lines: inout [String]) {
        let checks = acceptanceChecks
        guard !checks.isEmpty else { return }
        lines += ["", "## Acceptance checks", ""]
        for (label, passed) in checks {
            appendCheck(label, passed: passed, to: &lines)
        }
    }

    private var acceptanceChecks: [(String, Bool)] {
        let native = results.filter { $0.backend == "native-mlx" && $0.error == nil }
        var checks = results.compactMap { result -> (String, Bool)? in
            guard result.error != nil else { return nil }
            return ("\(result.backend) run completed", false)
        }
        guard !native.isEmpty else {
            checks.append(("Native benchmark produced a result", false))
            return checks
        }
        checks += [
            ("Incremental PCM streaming", native.allSatisfy { ($0.audioChunkCount ?? 0) > 1 }),
        ]
        if text.count > 800 {
            checks.append((
                "Bounded long-form segmentation",
                native.allSatisfy { ($0.requestCount ?? 0) > 1 }
            ))
        }
        checks.append((
            "Sustained generation above realtime",
            native.allSatisfy { ($0.realtimeMultiple ?? 0) > 1 }
        ))
        let played = native.filter { $0.underrunCount != nil }
        if !played.isEmpty {
            checks.append(("Continuous live PCM playback", played.allSatisfy { $0.underrunCount == 0 }))
        }
        if let nativeWarm = native.last?.timeToFirstAudioSeconds,
           let serverWarm = results.last(where: { $0.backend == "kokoro-server" && $0.error == nil })?.timeToFirstAudioSeconds
        {
            checks.append(("Native first audio faster than buffered Kokoro", nativeWarm < serverWarm))
        }
        if let diagnostics = nativeDiagnostics,
           let cancellationSucceeded = diagnostics.cancellationSucceeded
        {
            checks.append(("Prompt cancellation", cancellationSucceeded))
            let released = diagnostics.activeMemoryAfterUnloadGB <= diagnostics.activeMemoryBeforeLoadGB + 0.25
            checks.append(("Active MLX memory released", released))
            let cacheWithinBudget = diagnostics.cacheMemoryAfterUnloadGB <= diagnostics.cacheLimitGB + 0.1
            checks.append(("MLX cache within hardware budget", cacheWithinBudget))
        }
        return checks
    }

    private func appendCheck(_ label: String, passed: Bool, to lines: inout [String]) {
        lines.append("- \(passed ? "PASS" : "FAIL"): \(label)")
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "-"
    }

    private static func formatRate(_ value: Double?) -> String {
        value.map { String(format: "%.2fx", $0) } ?? "-"
    }
}

private extension String {
    func withTableEdges() -> String { "| \(self) |" }
}
