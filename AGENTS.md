# Coreo — Codex Implementation Guide

## Language & Framework
- Swift 5.9+, targeting iOS 17.0+
- SwiftUI for all UI
- AVFoundation for video capture, playback, and audio processing
- Accelerate framework for DSP (audio cross-correlation in sync engine)
- SwiftData for local persistence (projects, annotations)
- No third-party dependencies unless absolutely necessary — keep the dependency tree minimal

## Project Structure
```
Coreo/
├── App/
│   ├── CoreoApp.swift              # @main entry point
│   └── ContentView.swift           # Root navigation
├── Models/
│   ├── Project.swift               # Top-level container: name, date, angles, annotations
│   ├── VideoClip.swift             # Single video file: URL, duration, sync offset
│   └── Annotation.swift            # Timestamped note: text, timestamp, optional angle ref
├── Capture/
│   ├── CaptureView.swift           # Camera UI (SwiftUI)
│   ├── CaptureManager.swift        # AVCaptureSession coordination
│   └── ImportManager.swift         # Photo library import flow
├── Sync/
│   ├── SyncEngine.swift            # Audio cross-correlation to find offset between clips
│   ├── AudioExtractor.swift        # Extract PCM audio buffer from video asset
│   └── CrossCorrelation.swift      # DSP math — Accelerate vDSP for correlation
├── Playback/
│   ├── DualPlayerView.swift        # Side-by-side / PiP layout (SwiftUI)
│   ├── SyncedPlayerController.swift # Coordinates two AVPlayers with shared timeline
│   ├── TimelineView.swift          # Unified scrub bar with annotation markers
│   └── PlaybackControlsView.swift  # Play/pause, speed (0.25x–2x), frame step
├── Annotations/
│   ├── AnnotationListView.swift    # List of notes for a project
│   ├── AnnotationEditorView.swift  # Add/edit a timestamped note
│   └── AnnotationOverlayView.swift # Notes displayed on timeline during playback
├── Export/
│   ├── ExportManager.swift         # Composite annotated video for sharing
│   └── ShareSheet.swift            # UIActivityViewController wrapper
├── Storage/
│   ├── ProjectStore.swift          # SwiftData CRUD for projects
│   └── FileManager+Coreo.swift     # App sandbox file management helpers
└── Utilities/
    ├── TimeFormatting.swift         # mm:ss.ff display helpers
    └── AVAsset+Extensions.swift     # Convenience extensions on AVAsset/AVPlayer

CoreoTests/
├── UnitTests/
│   ├── SyncEngineTests.swift       # Cross-correlation accuracy, edge cases
│   ├── AudioExtractorTests.swift   # PCM extraction from test fixtures
│   ├── ModelTests.swift            # Project/VideoClip/Annotation serialization
│   └── TimeFormattingTests.swift   # Display formatting
└── IntegrationTests/
    ├── PlaybackSyncTests.swift     # Two-player coordination, seek accuracy
    └── ImportExportTests.swift     # Round-trip: import → annotate → export
```

## Quality Gates (must pass before task is complete)
```
swiftlint lint --strict
xcodebuild build -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | xcpretty
xcodebuild test -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CoreoTests/UnitTests 2>&1 | xcpretty
```

## Conventions
See `.project-context/conventions.md` for full details.
- Explicit types on all public function signatures (parameters and return types)
- `///` doc comments on all public types and methods
- File-level `// MARK: -` comments to section long files
- No force-unwraps (`!`) outside of test code — use guard-let or if-let
- No wildcard imports — import specific frameworks
- Prefer value types (struct, enum) over classes unless reference semantics are required
- Tests mirror source structure: `Coreo/Sync/SyncEngine.swift` → `CoreoTests/UnitTests/SyncEngineTests.swift`
- Use `@Observable` (iOS 17) over `ObservableObject` for new view models

## Running Tests
```
# Fast (every change) — unit tests only
xcodebuild test -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CoreoTests/UnitTests 2>&1 | xcpretty

# Full (before PR) — all tests
xcodebuild test -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | xcpretty
```

## Environment
- Xcode 15.0+ required
- iOS 17.0 minimum deployment target
- No CocoaPods/SPM dependencies initially — add only when the cost of building in-house clearly exceeds the dependency cost
- Test fixtures: short .mov clips in `CoreoTests/Fixtures/` for sync and playback tests
- Simulator-friendly: all unit tests must run on simulator (no device-only APIs in unit tests)

## Critical Constraints
- All video data stays on-device. No network calls, no analytics, no telemetry.
- AVFoundation operations must happen off the main thread — never block UI with video I/O.
- Memory pressure is real: video buffers are large. Use AVAssetReader streaming, not bulk loading.
- Sync offset must be stored per-clip, not recomputed on every playback.
- Export must preserve original video quality — no re-encoding unless compositing annotations.
- SwiftData model migrations must be handled gracefully from v1 onward.

## Known Gotchas
See `.project-context/knowledge/gotchas.md` — read before making changes.
