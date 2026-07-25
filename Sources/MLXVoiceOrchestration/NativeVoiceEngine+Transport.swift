import Foundation
import SwiftSpeechKit

/// Lets a host drive the native engine alongside unrelated transports —
/// file players, browser-owned players, Apple's on-device synthesizer —
/// without special-casing it at every control point.
///
/// Only the transport half is expressed here. Starting a read stays on the
/// concrete type, because `speak(text:voice:language:…)` needs a model and a
/// voice profile that no other transport has an equivalent for.
extension NativeVoiceEngine: PlaybackTransport {
    /// Both pre-audio phases collapse to `.preparing`: the distinction
    /// between "loading a model" and "generating the first samples" drives
    /// this engine's own progress UI, but for transport control they behave
    /// identically — pausable, active, and not yet seekable.
    public var transportState: TransportState {
        switch state {
        case .idle: .idle
        case .preparing, .synthesizing: .preparing
        case .speaking: .speaking
        case .paused: .paused
        }
    }
}
