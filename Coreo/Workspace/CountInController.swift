// CountInController.swift
// Coreo
//
// Count-in state and sequencing for explicit playback starts.

import Foundation
import Observation

/// Pure state machine for the optional playback count-in.
struct CountInStateMachine: Equatable {
    /// Current count-in phase.
    enum Phase: Equatable {
        /// No count-in is active.
        case idle

        /// Count-in is showing a numeric value.
        case counting(Int)

        /// Count-in finished and playback should start.
        case completed
    }

    /// Current phase of the state machine.
    private(set) var phase: Phase = .idle

    /// Starts the count-in at three.
    mutating func start() {
        phase = .counting(3)
    }

    /// Advances one count-in step.
    ///
    /// - Returns: True exactly when this tick completes the sequence.
    @discardableResult
    mutating func tick() -> Bool {
        guard case let .counting(value) = phase else { return false }
        if value > 1 {
            phase = .counting(value - 1)
            return false
        }
        phase = .completed
        return true
    }

    /// Cancels any active count-in.
    mutating func cancel() {
        phase = .idle
    }

    /// Whether the count-in is currently visible.
    var isCounting: Bool {
        if case .counting = phase {
            return true
        }
        return false
    }
}

/// Observable count-in controller with UserDefaults-backed preference.
@MainActor
@Observable
final class CountInController {
    /// UserDefaults key for count-in preference.
    static let preferenceKey = "countInEnabled"

    /// Current state-machine phase.
    private(set) var phase: CountInStateMachine.Phase = .idle

    /// Whether the count-in preference is enabled.
    var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: Self.preferenceKey)
            if !isEnabled {
                cancel()
            }
        }
    }

    /// Current visible count value.
    var currentCount: Int? {
        if case let .counting(value) = phase {
            return value
        }
        return nil
    }

    /// Whether the sequence is active.
    var isActive: Bool {
        stateMachine.isCounting
    }

    private let userDefaults: UserDefaults
    private var stateMachine = CountInStateMachine()
    private var task: Task<Void, Never>?

    /// Creates a count-in controller.
    ///
    /// - Parameter userDefaults: Preference store used for the count-in toggle.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isEnabled = userDefaults.bool(forKey: Self.preferenceKey)
    }

    /// Starts the count-in sequence.
    ///
    /// - Parameters:
    ///   - onCount: Callback fired for each visible count.
    ///   - onComplete: Callback fired once when the sequence completes.
    func start(
        onCount: @escaping @MainActor (Int) -> Void,
        onComplete: @escaping @MainActor () -> Void
    ) {
        cancel()
        stateMachine.start()
        phase = stateMachine.phase
        if let currentCount {
            onCount(currentCount)
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let completed = await MainActor.run { () -> Bool in
                    guard let self, self.stateMachine.isCounting else { return false }
                    let completed = self.stateMachine.tick()
                    self.phase = self.stateMachine.phase
                    if let currentCount = self.currentCount {
                        onCount(currentCount)
                    }
                    return completed
                }
                if completed {
                    await MainActor.run {
                        self?.finish(onComplete: onComplete)
                    }
                    return
                }
            }
        }
    }

    /// Cancels any active sequence.
    func cancel() {
        task?.cancel()
        task = nil
        stateMachine.cancel()
        phase = stateMachine.phase
    }

    /// Completes the active sequence and invokes playback start.
    ///
    /// - Parameter onComplete: Completion callback to invoke once.
    private func finish(onComplete: @escaping @MainActor () -> Void) {
        guard phase == .completed else { return }
        task?.cancel()
        task = nil
        stateMachine.cancel()
        phase = stateMachine.phase
        onComplete()
    }
}
