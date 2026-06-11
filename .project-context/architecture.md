# Coreo Architecture

## Module Map
- **App/** — Entry point (`CoreoApp`), root navigation (`ContentView`). Two-screen flow: Import → Workspace.
- **Import/** — Screen 1. Photo library picker (PHPicker), Files app picker (UIDocumentPicker), video thumbnail display, sync trigger. `ImportViewModel` manages import state and kicks off audio sync.
- **Workspace/** — Screen 2. The main screen — simultaneously preview, editor, and export trigger. `WorkspaceViewModel` is the central brain: owns all AVPlayers, unified timeline clock, playback state, annotation mode. `VideoGridView` arranges panels. `TimelineView` is the scrub bar.
- **Sync/** — FFT-based audio cross-correlation. `AudioExtractor` converts video → mono PCM float array (8kHz). `AudioSyncEngine` correlates each video against a reference, outputs per-video time offsets + confidence scores. Uses Accelerate.framework (vDSP). Pure computation, no UI.
- **Crop/** — Smart auto-crop via Vision framework. `PersonDetector` samples frames and runs `VNDetectHumanRectanglesRequest`. `SmartCropEngine` computes bounding box union + 15% padding. Falls back to full frame if no humans detected.
- **Annotations/** — Time-stamped annotation system. Each annotation has a `visibleTimeRange` and fades in/out. Three content types: PencilKit drawing, text label, directional arrow. `AnnotationOverlayView` renders visible annotations. `AnnotationToolbar` provides creation tools. `AnnotationTimeRangeControl` adjusts visibility window.
- **Speed/** — Per-segment playback speed and frame holds. `SpeedSegment` with rate 0.0 = freeze frame. UI for selecting timeline ranges and assigning speeds.
- **Export/** — Full AVMutableComposition pipeline. Composites all panels into split-screen, overlays annotation CALayers with timed opacity animations, applies speed/hold map, appends 1s branded end bumper. Outputs .mp4 via AVAssetExportSession.
- **Models/** — Core data types: `CoreoProject` (top-level container), `VideoAsset` (one video file), `LayoutEngine` (grid calculation for 2-6 panels). All Codable, persisted as JSON.
- **Utilities/** — `FFTHelper` (Accelerate wrappers for cross-correlation), `TimeFormatting` (seconds → "M:SS.ff").

## Data Flow
1. **Import** → user picks videos from Photos/Files → `VideoAsset.from(url:)` extracts metadata + thumbnail → displayed in horizontal scroll row
2. **Sync** → user taps "Sync & Go" → `AudioSyncEngine.sync()` extracts PCM from all videos, cross-correlates each against reference → produces `AudioSyncOutput` with per-video offsets and confidence scores
3. **Crop** → `SmartCropEngine.computeCropRects()` runs person detection on each video, computes activity regions → stored as `cropOverrides` on project
4. **Project creation** → `CoreoProject` assembled with videos, offsets, crops → navigates to Workspace
5. **Playback** → `WorkspaceViewModel` creates one `AVPlayer` per video, applies sync offsets, drives all from unified timeline clock → `VideoGridView` renders panels via `LayoutEngine` → `TimelineView` shows scrub bar
6. **Annotate** → user enters annotation mode → video pauses → user draws/types/arrows → `TimedAnnotation` created with 3s default visibility window → fades in/out during playback
7. **Export** → `ExportEngine` builds `AVMutableComposition` → positions panels via `CGAffineTransform` → `AnnotationCompositor` builds `CALayer` tree with timed opacity animations → `EndBumperGenerator` creates 1s bumper → `AVAssetExportSession` outputs .mp4 → share sheet

## Key Abstractions
- **CoreoProject** — Top-level container. Has 2-6 `VideoAsset`s, per-video sync offsets, layout/crop overrides, speed segments, annotations, audio source selection. The unit of persistence. Saved as JSON to Documents directory.
- **VideoAsset** — One video file. Holds: local URL, duration, dimensions, audio metadata, thumbnail data. Factory method `from(url:)` extracts everything from an AVAsset.
- **WorkspaceViewModel** — The brain. Owns all AVPlayers, unified timeline clock (currentTimeSeconds), playback state (playing, rate), annotation mode state. All players seek/play/pause in lockstep. Single source of truth for what's happening on screen.
- **TimedAnnotation** — Time-aware note. Has `visibleTimeRange` controlling when it appears. `opacity(at:)` method returns 0-1 with 0.2s fade. Three content types: drawing (PKDrawing), text (positioned label), arrow (directional). Per-project, not per-panel — overlays entire grid.
- **AudioSyncEngine** — Stateless computation. Input: array of video URLs + audio bitrates. Output: `AudioSyncOutput` with offsets + confidence. Uses FFT cross-correlation via Accelerate. Reference video = highest bitrate.
- **LayoutEngine** — Pure function. Input: video count, aspect ratios, container size. Output: array of CGRect panel frames. Evaluates all layout variants, picks the one maximizing visible video area.

## Dependency Graph
```
App → Import, Workspace
Import → Models, Sync, Crop
Workspace → Models, Annotations, Speed, Export, Utilities
Sync → Utilities (FFTHelper)
Crop → (standalone, uses Vision)
Annotations → Models (annotation types)
Speed → Models (SpeedSegment)
Export → Models, Annotations, Utilities
Models → (foundation, no deps)
Utilities → (foundation, no deps)
```
No circular dependencies. Import triggers Sync+Crop, then hands off to Workspace. Export reads everything but doesn't feed back.

## Known Complexity
- **FFT cross-correlation** (Sync/) — DSP math via Accelerate. Must handle: zero-padding to power-of-2, stereo→mono downsampling to 8kHz, peak detection with confidence thresholding. Performance target: <2s for typical 3-5 min clips.
- **Multi-AVPlayer synchronization** (Workspace/) — AVPlayer seek is async and imprecise. Keeping 2-6 players in sync during scrubbing and rate changes requires toleranceBefore:.zero seeks and careful ordering.
- **Timed annotation export** (Export/) — CALayer tree with CAKeyframeAnimation for per-annotation opacity, using AVVideoCompositionCoreAnimationTool. AVCoreAnimationBeginTimeAtZero timing. PencilKit drawings rasterized to UIImage → CALayer.contents.
- **Speed/hold time manipulation** (Export/) — Requires AVMutableComposition.scaleTimeRange() for each speed segment across all tracks. Holds insert frozen frames. Complex time math.
- **Memory pressure** — Up to 6 simultaneous AVPlayer video streams. Smart crop person detection loads frame samples. Export builds full composition in memory. Must be careful with large/long videos.
