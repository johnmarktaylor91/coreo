# Coreo Edge Cases

Purpose: catalog the edge and failure cases the current app actually handles, with the source mechanism for each claim. This is the code-grounded companion to `MANUAL-TESTING.md`, which covers human verification paths.

Grounded in code as of 2026-06-12 (post follow-up run). If code changes materially, regenerate rather than patch.

## Import

| Case | Current behavior | Source |
|---|---|---|
| Project size | Import requires at least 2 videos to sync and caps accepted videos at 6. Extra Files or Photos selections are truncated with an error message. | `Coreo/Import/ImportViewModel.swift:98`, `Coreo/Import/ImportViewModel.swift:374`, `Coreo/Import/ImportView.swift:73`, `Coreo/Import/ImportView.swift:470` |
| Picker UI cap | PhotosPicker is configured with `maxSelectionCount: 6`; add buttons are disabled once the model has 6 videos or sync is running. | `Coreo/Import/ImportView.swift:61`, `Coreo/Import/ImportView.swift:261`, `Coreo/Import/ImportView.swift:327` |
| Per-item file errors | Failed file imports append `ImportErrorItem` with filename, message, and retry URL; the UI renders each item and a Retry button when a retry URL exists. | `Coreo/Import/ImportViewModel.swift:164`, `Coreo/Import/ImportViewModel.swift:486`, `Coreo/Import/ImportView.swift:425` |
| Photo transfer failures | Photos transfer failures are kept per item, reported as import errors, and do not abort the entire selected batch. Photo failures have no retry URL. | `Coreo/Import/ImportView.swift:488`, `Coreo/Import/ImportView.swift:526` |
| Permission denial or inaccessible source | Permission/copy/read failures surface through the same per-item import error path; no source-specific recovery is implemented beyond retry when a file URL is available. | `Coreo/Import/ImportViewModel.swift:131`, `Coreo/Import/ImportViewModel.swift:134`, `Coreo/Import/ImportViewModel.swift:486` |
| Picker cancellation | Files picker cancellation is a no-op. Empty Photos selection is ignored. | `Coreo/Import/DocumentPickerView.swift:61`, `Coreo/Import/ImportView.swift:466` |
| Parallel imports | File imports run with bounded concurrency of 3 while preserving selected order; Photos transferable loading uses the same active-count pattern. | `Coreo/Import/ImportViewModel.swift:60`, `Coreo/Import/ImportViewModel.swift:444`, `Coreo/Import/ImportView.swift:488` |
| Copied media | Imported media is copied into the project media directory before metadata extraction; stored paths are project-relative. | `Coreo/Models/ProjectStore.swift:135`, `Coreo/Models/ProjectStore.swift:170`, `Coreo/Models/VideoAsset.swift:46` |

## Sync

| Case | Current behavior | Source |
|---|---|---|
| Too few videos | Fewer than 2 videos throws `insufficientVideos`; the import UI also disables sync below 2 videos. | `Coreo/Sync/AudioSyncEngine.swift:153`, `Coreo/Import/ImportViewModel.swift:98` |
| No-audio clips | Audio extraction failure for `.noAudioTrack` becomes per-video `.noAudio` status with confidence 0 and offset 0; no-audio clips do not abort sync if at least 2 other clips have audio. | `Coreo/Sync/AudioSyncEngine.swift:164`, `Coreo/Sync/AudioSyncEngine.swift:170`, `Coreo/Sync/AudioSyncEngine.swift:330` |
| Not enough audio-bearing clips | If fewer than 2 clips have audio after extraction, sync throws `insufficientAudioBearingVideos`. | `Coreo/Sync/AudioSyncEngine.swift:170` |
| Weak or quiet audio | Low confidence below `0.15` is marked unreliable and surfaced in the import alert as "Low confidence"; there is no separate RMS quiet-audio detector. | `Coreo/Sync/AudioSyncEngine.swift:90`, `Coreo/Sync/AudioSyncEngine.swift:303`, `Coreo/Import/ImportViewModel.swift:244` |
| Cancellation | Sync checks cancellation after extraction, before and after each correlation, and the import view cancels the task plus clears UI state. | `Coreo/Sync/AudioSyncEngine.swift:162`, `Coreo/Sync/AudioSyncEngine.swift:287`, `Coreo/Sync/AudioSyncEngine.swift:322`, `Coreo/Import/ImportView.swift:390` |
| Offset sign convention | Positive offset means the video starts after the reference; lag samples are divided by 8000 Hz and written directly to `syncOffsetSeconds`. | `Coreo/Sync/AudioSyncEngine.swift:27`, `Coreo/Sync/AudioSyncEngine.swift:297`, `Coreo/Import/ImportViewModel.swift:423` |
| Convention lock | Unit tests include an end-to-end synthetic offset lock and manual nudge round-trip coverage. | `CoreoTests/UnitTests/AudioSyncTests.swift`, `CoreoTests/UnitTests/PlaybackCoreTests.swift:96` |
| Manual nudge | Non-reference panels expose frame and 0.1s nudge buttons; the workspace mutates the stored offset and reapplies playback planning. | `Coreo/Workspace/VideoPanelView.swift:128`, `Coreo/Workspace/WorkspaceViewModel.swift:483` |
| Waveform nudge | Expanded waveform sync loads reference and selected envelopes, supports drag-to-offset, reset, and fixed nudge buttons. | `Coreo/Workspace/VideoGridView.swift:71`, `Coreo/Workspace/WaveformSyncNudgeView.swift:33`, `Coreo/Workspace/WaveformSyncNudgeView.swift:199`, `Coreo/Workspace/WaveformSyncNudgeView.swift:219` |

## Playback

| Case | Current behavior | Source |
|---|---|---|
| Audio session timing | The app sets the playback category during controller setup but activates the session only when playback starts. | `Coreo/Workspace/PlaybackController.swift:363`, `Coreo/Workspace/PlaybackController.swift:372`, `Coreo/Workspace/PlaybackController.swift:401` |
| Audio interruptions | Interruption began pauses playback; interruption ended resumes only if playback had been active. | `Coreo/Workspace/WorkspaceViewModel.swift:703`, `Coreo/Workspace/WorkspaceViewModel.swift:728` |
| Route changes | While playing, route changes reset the clock anchor and force-apply the current player plan. | `Coreo/Workspace/PlaybackController.swift:381`, `Coreo/Workspace/PlaybackController.swift:387` |
| Background/foreground | Background immediately saves, records whether playback was active, and pauses; foreground resumes only if it had been playing. | `Coreo/Workspace/WorkspaceViewModel.swift:675`, `Coreo/Workspace/WorkspaceViewModel.swift:690` |
| Late-start and ended clips | Player plans keep clips inactive before their timeline window and after their end; UI labels show "Starts in ..." or "Ended". | `Coreo/Workspace/PlayerSyncPlan.swift:44`, `Coreo/Workspace/PlaybackController.swift:298`, `Coreo/Workspace/VideoPanelView.swift:76` |
| Drift correction | Roughly once per second, active players more than one 30 fps frame from expected time are corrected with host-time `setRate`. | `Coreo/Workspace/PlaybackController.swift:585` |
| Hold crossing | Holds trigger when a clock tick crosses the hold start, not only when it lands exactly on the hold point; resume is scheduled by wall-clock duration. | `Coreo/Workspace/HoldPlaybackCoordinator.swift:33`, `Coreo/Workspace/PlaybackController.swift:472`, `Coreo/Workspace/PlaybackController.swift:503` |
| A-B loop rules | Loop A arms on first tap; B must be at least 0.5s away; playback wraps only when it crosses B while moving forward. | `Coreo/Workspace/LoopPlaybackCoordinator.swift:45`, `Coreo/Workspace/LoopPlaybackCoordinator.swift:106` |
| Count-in cancellation | Tapping play/pause during an active count-in cancels it; seeking, frame stepping, teardown, and disabling the preference also cancel it. | `Coreo/Workspace/WorkspaceViewModel.swift:157`, `Coreo/Workspace/WorkspaceViewModel.swift:200`, `Coreo/Workspace/WorkspaceViewModel.swift:253`, `Coreo/Workspace/CountInController.swift:70` |
| Scrub snapping | Interactive scrubs snap only to timeline start/end, annotation starts, and speed/hold boundaries. Clip starts are not snap targets. | `Coreo/Workspace/ScrubSnapTargets.swift:21`, `Coreo/Workspace/TimelineView.swift:369` |
| Seek storms | Scrub seeks are coalesced with generation checks; precise tolerance is used only for settles/frame-step style seeks. | `Coreo/Workspace/PlaybackController.swift:616` |

## Persistence

| Case | Current behavior | Source |
|---|---|---|
| Autosave debounce | Every project mutation schedules a 2 second debounced save snapshot. | `Coreo/Workspace/WorkspaceViewModel.swift:17`, `Coreo/Workspace/WorkspaceViewModel.swift:748` |
| Immediate save paths | Backgrounding and workspace teardown cancel the debounce and save immediately. | `Coreo/Workspace/WorkspaceViewModel.swift:684`, `Coreo/Workspace/WorkspaceViewModel.swift:592`, `Coreo/Workspace/WorkspaceViewModel.swift:765` |
| Atomic writes | Saves write a protected temp file, then replace or move it into `project.json`. | `Coreo/Models/ProjectStore.swift:203`, `Coreo/Models/ProjectStore.swift:221` |
| Schema versioning | `CoreoProject.currentSchemaVersion` is persisted; mismatched or corrupt project JSON is renamed aside and skipped. | `Coreo/Models/CoreoProject.swift:11`, `Coreo/Models/ProjectStore.swift:273`, `Coreo/Models/ProjectStore.swift:321` |
| Load on launch | ContentView loads the most recent saved project on first appearance and offers Continue or Start New in ImportView. | `Coreo/App/ContentView.swift:41`, `Coreo/Import/ImportView.swift:44`, `Coreo/Import/ImportView.swift:113` |
| Missing media detection | Loading marks each video `.available` or `.missing` by checking the copied media path. | `Coreo/Models/ProjectStore.swift:280`, `Coreo/Models/ProjectStore.swift:290` |
| Missing media remove | Workspace can remove a missing video, delete its media path if present, sanitize references, and rebuild players. | `Coreo/Workspace/WorkspaceViewModel.swift:390`, `Coreo/Models/ProjectStore.swift:304` |
| Missing media re-pick | Re-pick imports replacement media, preserves the original UUID and edit fields, warns if duration differs by more than 0.25s, and can delete a cancelled replacement copy. | `Coreo/Workspace/WorkspaceViewModel.swift:405`, `Coreo/Models/VideoAsset.swift:297`, `Coreo/Models/MediaReplacementPolicy.swift:10`, `Coreo/Workspace/WorkspaceViewModel.swift:451` |
| Force-quit recovery | Recovery depends on the last completed autosave, background save, or teardown save; a force quit inside the 2s debounce window can lose the latest mutation. | `Coreo/Workspace/WorkspaceViewModel.swift:748`, `Coreo/Workspace/WorkspaceViewModel.swift:765` |

## Export

| Case | Current behavior | Source |
|---|---|---|
| Cancellation | The coordinator cancels the export task, suppresses the share sheet, and the engine cancellation handler cancels `AVAssetExportSession`; cancelled or failed partial files are removed. | `Coreo/Workspace/ExportCoordinator.swift:113`, `Coreo/Export/ExportEngine.swift:571`, `Coreo/Export/ExportEngine.swift:587` |
| Disk preflight | ExportPlan estimates bytes from mapped duration plus bumper and render size, then ExportEngine compares against available temp volume capacity. | `Coreo/Export/ExportPlan.swift:141`, `Coreo/Export/ExportPlan.swift:218`, `Coreo/Export/ExportEngine.swift:92`, `Coreo/Export/ExportEngine.swift:607` |
| Holds | Export plans holds as per-clip freeze-frame edits and audio gaps, not black video gaps for active video clips. | `Coreo/Export/ExportPlan.swift:269`, `Coreo/Export/ExportEngine.swift:296` |
| Mirror toggle | Preview mirror is per video; export mirrors those panels only when the export preference is enabled. Annotations are rendered after panel compositing, so they are not flipped by panel mirror. | `Coreo/Workspace/WorkspaceViewModel.swift:245`, `Coreo/Workspace/ExportCoordinator.swift:32`, `Coreo/Export/ExportPlan.swift:350`, `Coreo/Export/PanelCompositor.swift:235` |
| Bumper lifecycle | Bumper generation is cancellable, cached by resolution/FPS when the file still exists, appended to track 0, and rendered without annotations. | `Coreo/Export/EndBumperGenerator.swift:64`, `Coreo/Export/EndBumperGenerator.swift:93`, `Coreo/Export/ExportEngine.swift:120`, `Coreo/Export/ExportEngine.swift:416` |
| Audio fallback | Export prefers the reference source if it has audio, otherwise the first source with audio; if no source has audio, export proceeds video-only. | `Coreo/Export/ExportPlan.swift:361`, `Coreo/Export/ExportEngine.swift:257` |
| Background export | Export requests a background task and cancels the session if the background task expires. | `Coreo/Export/ExportEngine.swift:455`, `Coreo/Export/ExportEngine.swift:481` |

## Annotations

| Case | Current behavior | Source |
|---|---|---|
| Always visible overlay | The workspace always mounts `AnnotationOverlayView`; hit testing is enabled only in annotation mode. | `Coreo/Workspace/WorkspaceView.swift:72`, `Coreo/Annotations/AnnotationOverlayView.swift:34`, `Coreo/Annotations/AnnotationOverlayView.swift:48` |
| Mixed canvas sizes | Annotations store the authoring canvas size and rasterize into the current destination size using normalized/grid coordinates. | `Coreo/Annotations/AnnotationModel.swift:29`, `Coreo/Annotations/AnnotationRasterizer.swift:13`, `Coreo/Annotations/AnnotationRasterizer.swift:174` |
| Letterbox/export mapping | Export panels use aspect-fit transforms and explicit clipping; annotation export renders a full-render transparent overlay after panels are composed. | `Coreo/Export/ExportPlan.swift:173`, `Coreo/Export/PanelCompositor.swift:210`, `Coreo/Annotations/AnnotationRasterizer.swift:341` |
| Time-warped visibility | Export maps composition time back to timeline time through `TimeMapper` before applying annotation opacity, so speed segments and holds affect visibility windows. | `Coreo/Annotations/AnnotationRasterizer.swift:346`, `Coreo/Models/TimeMapper.swift:178` |
| Fades | Timed annotations fade in over 0.2s and fade out over 0.2s; persistent annotations always return opacity 1. | `Coreo/Annotations/AnnotationModel.swift:70` |
| Raster cache | Preview and export use `AnnotationRasterCache`, keyed by annotation identity, content signature, and destination size. | `Coreo/Annotations/AnnotationRasterizer.swift:62`, `Coreo/Annotations/AnnotationOverlayView.swift:31`, `Coreo/Annotations/AnnotationRasterizer.swift:308` |

## Known Limitations

| Limitation | Evidence |
|---|---|
| Silent/quiet audio is not pre-filtered by RMS before correlation; it is handled indirectly by low confidence. | `Coreo/Sync/AudioSyncEngine.swift:90`, `Coreo/Utilities/FFTHelper.swift:298` |
| Export does not synthesize a silent audio track when all sources lack audio; it simply omits audio. | `Coreo/Export/ExportPlan.swift:361`, `Coreo/Export/ExportEngine.swift:257` |
| Export mirror is opt-in and independent from preview mirror by default. | `Coreo/Workspace/ExportCoordinator.swift:51`, `Coreo/Export/ExportPlan.swift:350` |
| Force-quitting before the 2s autosave debounce or before a background/teardown save can lose the latest edit. | `Coreo/Workspace/WorkspaceViewModel.swift:748` |
| Scrub snapping does not include clip starts/ends except timeline start/end. | `Coreo/Workspace/ScrubSnapTargets.swift:27` |
