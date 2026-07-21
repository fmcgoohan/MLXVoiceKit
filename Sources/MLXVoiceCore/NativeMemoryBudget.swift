import Foundation

public enum NativeHardwareTier: String, Codable, Sendable, Equatable {
    case unsupported
    case constrained
    case standard
    case highCapacity = "high-capacity"

    public var displayName: String {
        switch self {
        case .unsupported: "Unsupported"
        case .constrained: "Constrained"
        case .standard: "Standard"
        case .highCapacity: "High capacity"
        }
    }
}

public struct NativeMemoryBudget: Codable, Sendable, Equatable {
    public static let minimumSupportedMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    public static let minimumFreeDiskBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

    public let physicalMemoryBytes: UInt64
    public let cacheLimitBytes: Int
    public let hardwareTier: NativeHardwareTier

    public init(physicalMemoryBytes: UInt64) {
        self.physicalMemoryBytes = physicalMemoryBytes

        let gibibytes = physicalMemoryBytes / (1_024 * 1_024 * 1_024)
        switch gibibytes {
        case ..<16:
            cacheLimitBytes = 128 * 1_024 * 1_024
            hardwareTier = .unsupported
        case 16..<24:
            cacheLimitBytes = 256 * 1_024 * 1_024
            hardwareTier = .constrained
        case 24..<32:
            cacheLimitBytes = 512 * 1_024 * 1_024
            hardwareTier = .standard
        default:
            cacheLimitBytes = 1_024 * 1_024 * 1_024
            hardwareTier = .highCapacity
        }
    }

    public static var current: NativeMemoryBudget {
        NativeMemoryBudget(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    public var supportsNativeMLX: Bool {
        physicalMemoryBytes >= Self.minimumSupportedMemoryBytes
    }

    public var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_000_000_000
    }

    public var cacheLimitGB: Double {
        Double(cacheLimitBytes) / 1_000_000_000
    }
}
