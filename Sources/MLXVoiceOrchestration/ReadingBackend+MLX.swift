import SwiftReadingSession

public extension ReadingBackend {
    /// The backend identifier this orchestration stamps onto the sessions it
    /// creates. Exposed so callers can match on it (`session.backend == .nativeMLX`).
    static let nativeMLX = ReadingBackend("nativeMLX")
}
