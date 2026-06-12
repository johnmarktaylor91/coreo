# Coreo Performance Architecture

Purpose: document the performance mechanisms that are present in current source, with references. This file does not include benchmark numbers unless they are encoded in source or test commands.

Grounded in code as of 2026-06-12 (post follow-up run). If code changes materially, regenerate rather than patch.

## Sync And Audio

| Mechanism | What it does | Source |
|---|---|---|
| 8 kHz mono extraction | Audio sync and waveform generation share 8000 Hz mono PCM extraction, reducing sample volume before FFT or envelope work. | `Coreo/Sync/AudioExtractor.swift:47`, `Coreo/Sync/AudioSyncEngine.swift:94`, `Coreo/Sync/WaveformEnvelope.swift:34` |
| Off-main extraction | AVAssetReader setup and sample reading run in a detached user-initiated task. | `Coreo/Sync/AudioExtractor.swift:72` |
| Reader memory hygiene | `alwaysCopiesSampleData = false`, reserved sample capacity, per-buffer autoreleasepool, direct float extraction, and cancellation checks are used during reads. | `Coreo/Sync/AudioExtractor.swift:81`, `Coreo/Sync/AudioExtractor.swift:94`, `Coreo/Sync/AudioExtractor.swift:97`, `Coreo/Sync/AudioExtractor.swift:171` |
| Windowed correlation | Correlation uses at most the first 75 seconds of extracted audio. | `Coreo/Sync/AudioSyncEngine.swift:98`, `Coreo/Sync/AudioSyncEngine.swift:347` |
| Bounded correlation concurrency | Expensive pair correlations are capped at 2 active tasks. | `Coreo/Sync/AudioSyncEngine.swift:101`, `Coreo/Sync/AudioSyncEngine.swift:279` |
| Task-local FFT plan | Each correlation creates an FFT plan sized for that pair and reuses it inside `FFTHelper` when large enough. | `Coreo/Sync/AudioSyncEngine.swift:289`, `Coreo/Utilities/FFTHelper.swift:13`, `Coreo/Utilities/FFTHelper.swift:78` |
| Accelerate multiply and confidence | Frequency-domain multiply uses `vDSP_zvmul`; confidence is normalized by signal and reference energy. | `Coreo/Utilities/FFTHelper.swift:156`, `Coreo/Utilities/FFTHelper.swift:298` |
| Cooperative cancellation | Sync checks cancellation between extraction and correlation work, and cancellable offset finding checks before and after the FFT path. | `Coreo/Sync/AudioSyncEngine.swift:162`, `Coreo/Sync/AudioSyncEngine.swift:287`, `Coreo/Utilities/FFTHelper.swift:322` |

## Playback

| Mechanism | What it does | Source |
|---|---|---|
| Split observable model | `WorkspaceViewModel` owns project/editor state, while `PlaybackController`, `AnnotationStore`, `ExportCoordinator`, and `CountInController` isolate high-churn state. | `Coreo/Workspace/WorkspaceViewModel.swift:12`, `Coreo/Workspace/PlaybackController.swift:10`, `Coreo/Workspace/AnnotationStore.swift:9`, `Coreo/Workspace/ExportCoordinator.swift:10` |
| 30 Hz playhead scope | The 33.3 ms clock updates `PlaybackController.currentTimeSeconds`; the leaf `ActiveVideoPanelView` reads it, while layout and project state remain outside that ticking field. | `Coreo/Workspace/PlaybackController.swift:421`, `Coreo/Workspace/VideoGridView.swift:102`, `Coreo/Workspace/VideoGridView.swift:143` |
| Host-time rate changes | Active players use `setRate(_:time:atHostTime:)` so rate changes and activation windows are applied atomically against a host clock. | `Coreo/Workspace/PlaybackController.swift:548`, `Coreo/Workspace/PlaybackController.swift:568` |
| Seek coalescing | Every seek increments a generation, cancels the previous seek task, and only the latest generation can resume or apply the plan. | `Coreo/Workspace/PlaybackController.swift:616` |
| Scrub tolerance split | Precise settles use zero tolerance; interactive scrub seeks use 0.1 second tolerance. | `Coreo/Workspace/PlaybackController.swift:635`, `Coreo/Workspace/TimelineView.swift:349`, `Coreo/Workspace/TimelineView.swift:355` |
| Drift correction cadence | Drift checks are gated to about once per second and only adjust active players outside one 30 fps frame. | `Coreo/Workspace/PlaybackController.swift:585` |
| AVPlayer buffering | Player items set `preferredForwardBufferDuration = 5` and disable automatic waiting to minimize stalling. | `Coreo/Workspace/PlaybackController.swift:340` |
| LayoutCache | Workspace panel rectangles are memoized by container size, video IDs, dimensions, and panel overrides; project mutation invalidates the cache. | `Coreo/Workspace/LayoutCache.swift:9`, `Coreo/Workspace/LayoutCache.swift:24`, `Coreo/Workspace/WorkspaceViewModel.swift:17` |

## Annotations And Waveforms

| Mechanism | What it does | Source |
|---|---|---|
| Rasterize-once annotation cache | Annotation bitmaps are cached by annotation ID, content signature, and destination size; preview invalidates when content signatures change. | `Coreo/Annotations/AnnotationRasterizer.swift:62`, `Coreo/Annotations/AnnotationRasterizer.swift:88`, `Coreo/Annotations/AnnotationOverlayView.swift:54` |
| Shared preview/export rasterizer | Preview and export both render through `AnnotationRasterizer`, avoiding two separate rendering implementations. | `Coreo/Annotations/AnnotationOverlayView.swift:264`, `Coreo/Annotations/AnnotationRasterizer.swift:308` |
| Export annotation cache | `AnnotationExportFrameRenderer` has its own `AnnotationRasterCache` and applies cached overlays per frame. | `Coreo/Annotations/AnnotationRasterizer.swift:313`, `Coreo/Annotations/AnnotationRasterizer.swift:356` |
| Waveform envelope cache | Workspace caches envelopes by video ID and tracks loading IDs to avoid duplicate extraction tasks. | `Coreo/Workspace/WorkspaceViewModel.swift:55`, `Coreo/Workspace/WorkspaceViewModel.swift:512` |
| Bounded waveform buckets | Waveform envelopes use 0.035 second RMS buckets and reduce to at most 4000 buckets per clip. | `Coreo/Sync/WaveformEnvelope.swift:37`, `Coreo/Sync/WaveformEnvelope.swift:111` |
| Off-main waveform extraction | Waveform building calls the same async PCM extraction route, which does AVAssetReader work in a detached task. | `Coreo/Sync/WaveformEnvelope.swift:47`, `Coreo/Sync/AudioExtractor.swift:72` |

## Crop And Vision

| Mechanism | What it does | Source |
|---|---|---|
| Crop concurrent with sync | Import starts crop detection as `async let` while audio sync runs. | `Coreo/Import/ImportViewModel.swift:223` |
| Per-video crop concurrency | `SmartCropEngine.computeCropRects` runs one task per video and reassembles results in original order. | `Coreo/Crop/SmartCropEngine.swift:68`, `Coreo/Crop/SmartCropEngine.swift:80`, `Coreo/Crop/SmartCropEngine.swift:110` |
| Vision batch image API | Person detection uses `AVAssetImageGenerator.images(for:)` over sampled times instead of one synchronous copy per frame. | `Coreo/Crop/PersonDetector.swift:73`, `Coreo/Crop/PersonDetector.swift:82` |
| Detection memory bounds | Generated frames are capped to 1280x1280, detection runs off-main, and per-frame Vision work is wrapped in autoreleasepool. | `Coreo/Crop/PersonDetector.swift:67`, `Coreo/Crop/PersonDetector.swift:77`, `Coreo/Crop/PersonDetector.swift:87` |
| Full-body request | Vision human rectangles are configured with `upperBodyOnly = false` for full-body dance framing. | `Coreo/Crop/PersonDetector.swift:137` |
| Crop fallback | Detection errors return nil crop for that video, which means full-frame rendering. | `Coreo/Crop/SmartCropEngine.swift:96`, `Coreo/Crop/SmartCropEngine.swift:21` |

## Export

| Mechanism | What it does | Source |
|---|---|---|
| Pure planning before encoding | `ExportPlan` computes inserts, timeline edits, panels, audio source, FPS, and disk estimate without running an export session. | `Coreo/Export/ExportPlan.swift:11`, `Coreo/Export/ExportPlan.swift:97` |
| Disk preflight | Estimated output bytes are checked against temp volume capacity before composition export starts. | `Coreo/Export/ExportPlan.swift:218`, `Coreo/Export/ExportEngine.swift:92`, `Coreo/Export/ExportEngine.swift:607` |
| Custom CI compositor | `PanelCompositor` serializes render requests on a user-initiated queue, clips each panel, and uses a hardware CIContext. | `Coreo/Export/PanelCompositor.swift:110`, `Coreo/Export/PanelCompositor.swift:112`, `Coreo/Export/PanelCompositor.swift:131` |
| Off-main orchestration | Export work is launched in a `Task`, and progress is posted back through the coordinator. | `Coreo/Workspace/ExportCoordinator.swift:74`, `Coreo/Export/ExportEngine.swift:163` |
| Export cancellation | Task cancellation cancels the underlying export session and removes partial output on cancelled/failed paths. | `Coreo/Export/ExportEngine.swift:571`, `Coreo/Export/ExportEngine.swift:587` |
| Bumper cache | End bumper generation is cached by resolution and FPS while the temp file still exists. | `Coreo/Export/EndBumperGenerator.swift:64`, `Coreo/Export/EndBumperGenerator.swift:357` |
| Background task | Export starts a UIKit background task and cancels if the background task expires. | `Coreo/Export/ExportEngine.swift:455`, `Coreo/Export/ExportEngine.swift:481` |

## Persistence

| Mechanism | What it does | Source |
|---|---|---|
| Debounced autosave | Project mutation schedules a 2 second delayed save and cancels older pending saves. | `Coreo/Workspace/WorkspaceViewModel.swift:17`, `Coreo/Workspace/WorkspaceViewModel.swift:748` |
| Immediate save on lifecycle | Background and teardown paths cancel pending debounce and write immediately. | `Coreo/Workspace/WorkspaceViewModel.swift:675`, `Coreo/Workspace/WorkspaceViewModel.swift:592`, `Coreo/Workspace/WorkspaceViewModel.swift:765` |
| Atomic project JSON | Saves write to a temp file and replace or move into `project.json`. | `Coreo/Models/ProjectStore.swift:203`, `Coreo/Models/ProjectStore.swift:221` |
| Protected copied media | Imported media is copied into the project directory and excluded from backup. | `Coreo/Models/ProjectStore.swift:170`, `Coreo/Models/ProjectStore.swift:177` |

## Not Yet Measured

| Gap | Current evidence |
|---|---|
| No on-device Instruments profile is recorded in repo. | No Instruments trace or profiling report exists in current files. |
| Verification so far is simulator/build/test based, not device thermal or memory pressure based. | Required gate is `xcodebuild test -scheme Coreo -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`. |
| No sourced peak memory, FPS, or export-time numbers are available here. | The source defines caps such as 75s correlation windows, 2 concurrent correlations, 4000 waveform buckets, and 5s player buffers, but not measured outcomes. |

## Known Performance Limits

| Limit | Evidence |
|---|---|
| Audio extraction still accumulates full PCM arrays before sync/windowing and waveform downsampling. | `Coreo/Sync/AudioExtractor.swift:93`, `Coreo/Sync/AudioSyncEngine.swift:178`, `Coreo/Sync/WaveformEnvelope.swift:49` |
| `FFTHelper.crossCorrelate` still allocates and returns the full correlation array, although callers only need the lag and confidence. | `Coreo/Utilities/FFTHelper.swift:46`, `Coreo/Utilities/FFTHelper.swift:231` |
| Per-video Vision frame processing is sequential inside each video task. | `Coreo/Crop/PersonDetector.swift:82` |
| Some compact controls intentionally use plain button style or 28x24 visual frames, though surrounding accessibility coverage varies by control. | `Coreo/Workspace/VideoPanelView.swift:144`, `Coreo/Workspace/VideoPanelView.swift:214` |
