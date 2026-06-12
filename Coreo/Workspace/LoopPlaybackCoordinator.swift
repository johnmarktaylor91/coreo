// LoopPlaybackCoordinator.swift
// Coreo
//
// Pure A-B loop policy for playback.

import Foundation

/// A valid A-B loop region.
struct LoopRegion: Equatable {
    /// Loop start in timeline seconds.
    let startSeconds: Double

    /// Loop end in timeline seconds.
    let endSeconds: Double
}

/// Session-only A-B loop state.
enum ABLoopState: Equatable {
    /// No loop points are set.
    case cleared

    /// Point A has been set and the next tap should set B.
    case armed(startSeconds: Double)

    /// A valid loop region is active.
    case active(LoopRegion)
}

/// Result of handling a loop-control activation.
enum ABLoopActivationResult: Equatable {
    /// Point A was set.
    case armed

    /// Point B was set and the loop is active.
    case activated

    /// The active loop was cleared.
    case cleared

    /// Point B was too close to point A.
    case rejectedTooShort
}

/// Pure state machine for setting, clearing, and crossing an A-B loop.
struct LoopPlaybackCoordinator {
    /// Minimum allowed A-B loop duration.
    static let minimumDurationSeconds = 0.5

    /// Current loop state.
    private(set) var state: ABLoopState = .cleared

    /// Handles one UI activation at the current playhead.
    ///
    /// - Parameter currentTimeSeconds: Current playhead position in timeline seconds.
    /// - Returns: The transition result.
    @discardableResult
    mutating func activate(at currentTimeSeconds: Double) -> ABLoopActivationResult {
        switch state {
        case .cleared:
            state = .armed(startSeconds: currentTimeSeconds)
            return .armed
        case let .armed(startSeconds):
            let start = min(startSeconds, currentTimeSeconds)
            let end = max(startSeconds, currentTimeSeconds)
            guard end - start >= Self.minimumDurationSeconds else {
                return .rejectedTooShort
            }
            state = .active(LoopRegion(startSeconds: start, endSeconds: end))
            return .activated
        case .active:
            state = .cleared
            return .cleared
        }
    }

    /// Clears loop state.
    mutating func clear() {
        state = .cleared
    }

    /// Clears the loop if it no longer fits within the timeline.
    ///
    /// - Parameter durationEndSeconds: Current timeline end.
    /// - Returns: True if an active or armed loop was cleared.
    @discardableResult
    mutating func clearIfOutOfBounds(durationEndSeconds: Double) -> Bool {
        switch state {
        case let .armed(startSeconds) where startSeconds > durationEndSeconds:
            state = .cleared
            return true
        case let .active(region) where region.endSeconds > durationEndSeconds:
            state = .cleared
            return true
        default:
            return false
        }
    }

    /// Returns a loop-wrap seek target if playback crossed B.
    ///
    /// - Parameters:
    ///   - previousSeconds: Previous timeline time.
    ///   - currentSeconds: Current timeline time.
    ///   - isPlaying: Whether playback is currently active.
    /// - Returns: Loop start when playback should wrap, otherwise nil.
    func loopSeekTarget(
        previousSeconds: Double,
        currentSeconds: Double,
        isPlaying: Bool
    ) -> Double? {
        guard isPlaying, case let .active(region) = state else { return nil }
        guard currentSeconds >= previousSeconds else { return nil }
        if previousSeconds < region.endSeconds, currentSeconds >= region.endSeconds {
            return region.startSeconds
        }
        return nil
    }
}
