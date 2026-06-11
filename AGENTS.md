# Coreo — Codex Implementation Guide

## Language & Framework
- Swift 5.9+, targeting iOS 16.0+
- SwiftUI for all UI, UIKit via UIViewRepresentable where needed (AVPlayerLayer, PencilKit, document picker)
- AVFoundation for video playback, audio extraction, and export composition
- Accelerate.framework for FFT-based audio cross-correlation
- Vision.framework for person detection (smart auto-crop)
- PencilKit for freehand drawing annotations
- JSON file persistence (Codable structs saved to Documents directory). No CoreData, no SwiftData, no CloudKit.
- No third-party dependencies. Apple frameworks only.

## Project Structure
```
Coreo/
├── App/
│   ├── CoreoApp.swift              # @main entry point
│   └── ContentView.swift           # Root navigation (Import → Workspace)
├── Import/
│   ├── ImportView.swift            # Screen 1: video drop zone
│   ├── ImportViewModel.swift       # Import state, sync trigger
│   ├── VideoThumbnailView.swift    # Thumbnail card in horizontal row
│   └── DocumentPickerView.swift    # UIDocumentPicker wrapper
├── Workspace/
│   ├── WorkspaceView.swift         # Screen 2: preview + edit + export
│   ├── WorkspaceViewModel.swift    # Central brain: AVPlayers, timeline, state
│   ├── VideoGridView.swift         # Split-screen panel layout
│   ├── VideoPanelView.swift        # Individual panel with AVPlayerLayer
│   ├── TimelineView.swift          # Unified scrub bar + coverage + markers
│   └── PlaybackControlsView.swift  # Play/pause, speed, time display
├── Sync/
│   ├── AudioSyncEngine.swift       # FFT cross-correlation orchestrator
│   └── AudioExtractor.swift        # AVAsset → mono PCM float array (8kHz)
├── Crop/
│   ├── PersonDetector.swift        # Vision VNDetectHumanRectanglesRequest
│   └── SmartCropEngine.swift       # Bounding box union + padding
├── Annotations/
│   ├── AnnotationModel.swift       # TimedAnnotation, AnnotationContent, text/arrow/drawing types
│   ├── AnnotationOverlayView.swift # Renders visible annotations at current time
│   ├── AnnotationToolbar.swift     # Floating tool palette (pencil, text, arrow, eraser, color)
│   ├── AnnotationTimeRangeControl.swift  # Mini timeline for annotation visibility window
│   ├── TextAnnotationView.swift    # Renders a text label
│   ├── ArrowAnnotationView.swift   # Renders a directional arrow
│   └── AnnotationMarkerView.swift  # Colored dots on timeline
├── Speed/
│   ├── SpeedSegmentModel.swift     # SpeedSegment + SpeedMap types
│   ├── SpeedControlView.swift      # Range selection + speed picker UI
│   └── HoldMarkerView.swift        # Pause icons on timeline
├── Export/
│   ├── ExportEngine.swift          # AVMutableComposition pipeline
│   ├── AnnotationCompositor.swift  # CALayer tree with timed opacity animations
│   ├── EndBumperGenerator.swift    # 1s branded end card
│   ├── ExportProgressView.swift    # Progress overlay
│   └── ShareSheetView.swift        # UIActivityViewController wrapper
├── Models/
│   ├── CoreoProject.swift          # Main project data model (Codable, JSON persistence)
│   ├── VideoAsset.swift            # Video file metadata + thumbnail
│   └── LayoutEngine.swift          # Auto-layout calculation for 2-6 panels
├── Utilities/
│   ├── FFTHelper.swift             # Accelerate vDSP wrappers for cross-correlation
│   └── TimeFormatting.swift        # Seconds → "M:SS.ff" formatting
└── Resources/
    └── Assets.xcassets             # App icon, accent color

CoreoTests/
├── UnitTests/
│   ├── ModelTests.swift            # CoreoProject + VideoAsset serialization
│   ├── AnnotationModelTests.swift  # Opacity calculation, Codable round-trip
│   ├── LayoutEngineTests.swift     # Grid layout correctness
│   ├── AudioSyncTests.swift        # FFT cross-correlation, SmartCrop
│   └── TimeFormattingTests.swift   # Display formatting
└── Fixtures/                       # Short .mov clips for sync/playback tests
```

## Quality Gates (must pass before task is complete)
```
swiftlint
swiftformat --lint .
xcodebuild test -scheme Coreo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify
```

## Conventions
See `.project-context/conventions.md` for full details.
- Explicit types on all public function signatures (parameters and return types)
- `///` doc comments on all public types and methods
- File-level `// MARK: -` comments to section long files
- No force-unwraps (`!`) outside of test code — use guard-let or if-let
- No wildcard imports — import specific frameworks
- Prefer value types (struct, enum) over classes unless reference semantics are required (ViewModels use class + ObservableObject)
- Use `ObservableObject` + `@Published` for ViewModels (iOS 16 target, not @Observable)
- Use `@MainActor` on all ViewModels
- Tests mirror source structure: `Coreo/Sync/AudioSyncEngine.swift` → `CoreoTests/UnitTests/AudioSyncTests.swift`

## Running Tests
```
# Fast (every change) — unit tests only
xcodebuild test -scheme Coreo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:CoreoTests/UnitTests | xcbeautify

# Full (before PR) — all tests
xcodebuild test -scheme Coreo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify
```

## Environment
- Xcode 15.0+ required
- iOS 16.0 minimum deployment target
- No CocoaPods/SPM dependencies — Apple frameworks only
- Project generated via xcodegen (project.yml in repo root)
- Test fixtures: short .mov clips in `CoreoTests/Fixtures/` for sync and playback tests
- Simulator-friendly: all unit tests must run on simulator (no device-only APIs in unit tests)

## Critical Constraints
- All video data stays on-device. No network calls, no analytics, no telemetry.
- AVFoundation operations must happen off the main thread — never block UI with video I/O.
- Memory pressure is real: up to 6 simultaneous video streams. Use AVAssetReader streaming, not bulk loading.
- Sync offsets are computed once and stored on CoreoProject — not recomputed on every playback.
- Export composites all panels + annotations into a single .mp4. Uses AVVideoCompositionCoreAnimationTool for annotation overlay.
- Projects persist as JSON to Documents directory. Videos are referenced by URL, not copied.
- Dark theme throughout: bg #0A0A0A, panels #1A1A1A, accent coral #FF6B35.

## Known Gotchas
See `.project-context/knowledge/gotchas.md` — read before making changes.
