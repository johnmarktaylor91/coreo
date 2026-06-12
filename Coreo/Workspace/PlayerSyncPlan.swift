// PlayerSyncPlan.swift
// Coreo
//
// Pure playback planning for synchronizing AVPlayers to the unified timeline.

import CoreMedia
import Foundation

/// A pure plan describing what each player should do at one timeline instant.
struct PlayerSyncPlan: Equatable {
    /// Desired state for a single video player.
    enum DesiredState: Equatable {
        /// The player should be active at a clip-local time and playback rate.
        case active(clipSeconds: Double, rate: Float)

        /// The player should be paused at a clip-local boundary time.
        case inactive(clipSeconds: Double, reason: InactiveReason)
    }

    /// Why a player is inactive at a timeline instant.
    enum InactiveReason: Equatable {
        /// The clip has not reached its active timeline window yet.
        case beforeStart(startsInSeconds: Double)

        /// The clip active window has ended.
        case afterEnd
    }

    /// Desired states in project video order.
    let states: [DesiredState]

    /// Builds a synchronization plan for all clips.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Unified timeline position.
    ///   - mapper: Time mapper built from the current project.
    ///   - rate: Effective playback rate for active players.
    /// - Returns: A player synchronization plan.
    static func make(
        timelineSeconds: Double,
        mapper: TimeMapper,
        rate: Float
    ) -> PlayerSyncPlan {
        let states = mapper.clips.map { clip in
            let localSeconds = timelineSeconds - clip.syncOffsetSeconds
            if localSeconds < clip.clipStartSeconds {
                return DesiredState.inactive(
                    clipSeconds: clip.clipStartSeconds,
                    reason: .beforeStart(startsInSeconds: clip.clipStartSeconds - localSeconds)
                )
            }
            if localSeconds > clip.clipEndSeconds {
                return DesiredState.inactive(clipSeconds: clip.clipEndSeconds, reason: .afterEnd)
            }
            return DesiredState.active(
                clipSeconds: min(max(localSeconds, clip.clipStartSeconds), clip.clipEndSeconds),
                rate: rate
            )
        }
        return PlayerSyncPlan(states: states)
    }

    /// Expected clip time for a state.
    ///
    /// - Parameter state: Desired state to inspect.
    /// - Returns: Clip-local time as `CMTime`.
    static func cmTime(for state: DesiredState) -> CMTime {
        let seconds: Double = switch state {
        case let .active(clipSeconds, _), let .inactive(clipSeconds, _):
            clipSeconds
        }
        return CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }
}
