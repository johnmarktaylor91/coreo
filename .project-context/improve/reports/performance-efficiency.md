# Coreo Performance & Efficiency Survey

Survey agent: PERFORMANCE & EFFICIENCY lens (1 of 6). Date: 2026-06-11.
Method: static analysis only (xcodebuild broken on this machine). Every Swift file in
`Coreo/` and `CoreoTests/` was read in full. Line numbers refer to current `main`
(commit 9346ce5 + uncommitted working tree).

Severity scale: Critical (memory blowup / jetsam / pipeline-scale waste),
High (user-visible latency, sustained CPU/energy waste), Medium (measurable but bounded),
Low (cheap polish). Each finding: VERIFIED (read in source) vs INFERRED (reasoned, needs
profiling to confirm magnitude).

---

## CRITICAL

### C1. FFT cross-correlation allocates ~200 MB per video pair and runs ALL pairs concurrently (unbounded) — ~1 GB transient for 6 videos

**Files:** `Coreo/Utilities/FFTHelper.swift:21-156`, `Coreo/Sync/AudioSyncEngine.swift:108-141`
**Status:** VERIFIED. **Confidence: high.**

What's wrong:

1. `FFTHelper.crossCorrelate` pads both signals to the next power of two >= `signal.count + reference.count` (FFTHelper.swift:30-32). For two 5-minute clips at 8 kHz (2.4 M samples each), combined = 4.8 M -> fftLength = 2^23 = 8,388,608 floats. Live allocations within one call:
   - `paddedSignal` + `paddedReference`: 2 x 33.5 MB = 67 MB (lines 42-45; stay alive for the whole function)
   - `signalReal/Imag`, `refReal/Imag`: 4 x 16.8 MB = 67 MB (lines 48-51)
   - `productReal/Imag`: 33.5 MB (lines 107-108)
   - `correlation`: 33.5 MB (line 127)
   - Total ~200 MB simultaneously, plus the `vDSP_create_fftsetup` twiddle tables for log2n=23 (tens of MB, rebuilt and destroyed per call, lines 36-39).
2. `AudioSyncEngine.sync` adds every non-reference video to a `withThrowingTaskGroup` with **no concurrency cap** (AudioSyncEngine.swift:108-133). With 6 videos, 5 correlations can run concurrently -> ~1 GB transient, plus 5 decoded PCM arrays (~9.6 MB each) and the reference array. `PERFORMANCE.md` claims "~40 MB peak" and lists "Unbounded concurrent correlations (cap at 2)" as a *deferred* fix — the cap was never implemented. This is a jetsam risk on any device, and a certainty on older 3-4 GB devices.

Recommended change (in priority order; all are compatible):

1. **Cap correlation concurrency at 2** in `AudioSyncEngine.sync`: add tasks lazily — seed the group with 2 tasks, add the next task each time one completes (standard `while let result = try await group.next()` + `addTask` pattern). ~10 lines.
2. **Share one FFT setup**: hoist `vDSP_create_fftsetup` out of `crossCorrelate` — compute the max log2n across all pairs once per sync run and pass the setup in (it is valid for any length <= its creation length). Eliminates repeated multi-MB twiddle-table builds.
3. **Scope intermediates for early release**: wrap padded-array packing in a nested function/closure so `paddedSignal`/`paddedReference` are released before the inverse FFT; reuse `signalReal/Imag` as the product destination (vDSP allows in-place: write product into `signalReal/Imag` instead of allocating `productReal/Imag`). Cuts per-pair peak roughly in half.
4. **(Algorithmic, larger win) Windowed correlation:** dance videos of the same routine rarely need full-clip alignment range. Correlate a 60-90 s window of the secondary signal against the full reference (or use overlap-save block correlation). FFT size drops from 2^23 to ~2^21 or less; memory and time drop ~4x. Keep full-length as fallback when windowed confidence < threshold. This changes sync behavior, so gate behind the confidence check.

Blast radius: `FFTHelper.swift`, `AudioSyncEngine.swift`. No API change visible to callers (`findOffset` signature unchanged).
Verification: unit tests in `CoreoTests/UnitTests/AudioSyncTests.swift` must still pass (offset accuracy +-1 sample at 8 kHz); add a test asserting two 300 s synthetic signals sync within memory budget (instrument via `os_signpost` or simply assert no crash + correct lag). Profile with Instruments Allocations: peak during 6-video sync should drop from ~1 GB to <150 MB.

### C2. Four performance fixes documented as DONE in PERFORMANCE.md are absent from the source (regression or doc drift)

**Files:** `Coreo/Sync/AudioExtractor.swift:90-99,126-156`, `Coreo/Utilities/FFTHelper.swift:110-113`, vs `PERFORMANCE.md` High fixes #4-#7
**Status:** VERIFIED (absence confirmed by reading the files). **Confidence: high.**

PERFORMANCE.md (2026-03-17 sprint) lists these as fixed, but the code does not contain them:

| Documented fix | Current reality |
|---|---|
| #4 "autoreleasepool in AudioExtractor wrapping each read-loop iteration" | Read loop at AudioExtractor.swift:92-99 has **no autoreleasepool**. CMSampleBuffers and their block buffers accumulate across the entire decode of a 5-min track. |
| #5 "Double copy fixed: single copy directly into [Float]" | `extractFloats` (AudioExtractor.swift:138-155) still does CMBlockBuffer -> `Data` (copy 1) -> `Array(floatBuffer)` (copy 2). |
| #6 "reserveCapacity pre-computed from track duration" | `var allSamples: [Float] = []` at line 90, **no reserveCapacity**; 2.4 M-element array grows by repeated reallocation. (EDGE-CASES.md even documents an `Int(NaN)`-guard for this nonexistent reserveCapacity call.) |
| #7 "Scalar loop in FFT complex multiply replaced with vDSP_zvmul" | FFTHelper.swift:110-113 is a **scalar for-loop** over `halfLength` (~4.2 M iterations for long clips). |

Either the fixes were lost in a repo reconstruction or the doc is aspirational. Re-apply all four:

1. Wrap each `while reader.status == .reading` iteration body in `autoreleasepool { ... }`.
2. In `extractFloats`, use `CMBlockBufferGetDataPointer` when `CMBlockBufferIsRangeContiguous` (it always is for LPCM reader output) and copy once into `[Float](unsafeUninitializedCapacity:)`; keep the `Data` path only as fallback.
3. Pre-compute capacity: `allSamples.reserveCapacity(Int((durationSeconds * targetSampleRate).rounded(.up)))` with a finite-guard fallback (load `.duration` before the read loop — already async-loaded context).
4. Replace the scalar multiply with `vDSP_zvmul(&sigSplit, 1, &refSplit, 1, &outSplit, 1, vDSP_Length(halfLength), -1)` (conjugate flag -1), with explicit special-case handling of the zrip-packed bin 0 (see M4).

Blast radius: 2 files, ~40 lines. Verification: `AudioSyncTests` unchanged; Allocations instrument shows flat (not saw-tooth-growing) footprint during extraction.
Also update PERFORMANCE.md to match reality once landed.

---

## HIGH

### H1. PKDrawing is deserialized AND rasterized on every SwiftUI body evaluation

**File:** `Coreo/Annotations/AnnotationOverlayView.swift:282-292`
**Status:** VERIFIED. **Confidence: high.**

`drawingView(for:)` runs `try? PKDrawing(data:)` followed by `pkDrawing.image(from:scale: 2.0)` — a full PencilKit decode plus a container-size 2x raster (~3-6 MB image) — inside a `@ViewBuilder` that re-executes every time the observed `WorkspaceViewModel` publishes (every published property: playhead ticks while scrubbing in annotation mode, tool changes, selection changes, opacity fades). This is PERFORMANCE.md's deferred "PencilKit annotation re-renders every frame," still open. If the overlay is ever shown during playback (which DESIGN.md requires — see For JMT note), this becomes a 30 Hz decode+raster per drawing annotation and will visibly drop frames.

Recommended change: cache the rasterized `UIImage` keyed by `(annotation.id, containerSize)` — e.g., a small `@State private var drawingImageCache: [UUID: UIImage]` in `AnnotationOverlayView` (invalidate entries on size change and on annotation delete), or better, an `NSCache<NSUUID, UIImage>` owned by `WorkspaceViewModel` populated off-main via `Task.detached`. Opacity fades must apply to the cached image via `.opacity()` (already the case at line 34), so the raster never needs to re-render during a fade.

Blast radius: `AnnotationOverlayView.swift` (+ optionally `WorkspaceViewModel`). Verification: Instruments Time Profiler while toggling annotation mode with 5 drawing annotations — `PKDrawing.image` should appear once per annotation, not continuously.

### H2. Single monolithic ObservableObject invalidates the entire workspace view tree at 30 Hz

**Files:** `Coreo/Workspace/WorkspaceViewModel.swift:28,434-447`, consumers: `WorkspaceView.swift:14`, `VideoGridView.swift:16`, `TimelineView.swift:21`, `PlaybackControlsView.swift:13`, `SpeedControlView.swift:22`, `AnnotationOverlayView.swift:14`
**Status:** VERIFIED (mechanism); INFERRED (magnitude — needs profiling). **Confidence: high on mechanism.**

`currentTimeSeconds` is `@Published` and updated at ~30 Hz by the periodic time observer. Every view holding `@ObservedObject var viewModel: WorkspaceViewModel` re-evaluates its whole `body` 30x/sec during playback — including the top bar, edit tools, audio menu, and the video grid, none of which depend on the playhead except via small leaf labels. Concrete per-tick waste found:

- `VideoGridView.panelRects` recomputes `LayoutEngine.calculateLayout` (candidate enumeration + scoring) on every body call (VideoGridView.swift:63-88).
- `TimelineView` rebuilds coverage bars, speed overlays, and annotation markers per tick (TimelineView.swift:43-88) when only the playhead x changed.
- `VideoPanelView`/`AVPlayerLayerView.updateUIView` runs per tick per panel (see H3).

Recommended change (pick one; first is the modern fix):

1. **Migrate `WorkspaceViewModel` to `@Observable` (Observation framework)** and change consumers to plain `let viewModel:`/`@Bindable`. Property-level dependency tracking means only views that actually read `currentTimeSeconds` re-evaluate on ticks. Deployment target is iOS 17+ (project uses iOS 26 SDK per Xcode 26.5), so this is available. Mechanical changes: `@Published` removed, `@StateObject` -> `@State`, `@ObservedObject` -> nothing, bindings via `@Bindable`.
2. Alternatively, split a `PlaybackClock: ObservableObject { @Published var currentTimeSeconds }` child object; only `TimelineView`'s scrub area, `PlaybackControlsView.timeDisplay`, and the inactive-overlay logic observe it.

Plus, independently: **cache layout rects** — compute `panelRects` only when `(videos.count, dimensions, layoutOverrides, containerSize)` changes; store in the VM or a `@State` with `onChange`.

Blast radius: all Workspace/* views, ImportViewModel optionally (same pattern). This is the highest-leverage energy fix in the app: it converts the steady-state playback cost from "re-diff entire screen at 30 Hz" to "update two Text labels and one offset."
Verification: SwiftUI Instruments template — "View Body" count during 10 s of playback should drop from hundreds/sec to ~60/sec (playhead leaf views only).

### H3. New CAShapeLayer + UIBezierPath mask allocated on every updateUIView call (30 Hz x 6 panels)

**File:** `Coreo/Workspace/VideoPanelView.swift:154-190`
**Status:** VERIFIED. **Confidence: high.**

`updateUIView` calls `applyCropMask` unconditionally; it allocates a fresh `CAShapeLayer` and `UIBezierPath` and reassigns `view.layer.mask` (lines 187-189) on every SwiftUI update — with H2 unfixed, that's up to 180 layer allocations/sec during playback, each invalidating the panel's render tree. This is PERFORMANCE.md's deferred item, still open. Additional latent bug: the mask is computed from `view.bounds` at update time; at first layout bounds can be `.zero` (guarded -> mask silently skipped) and the mask is never re-applied on rotation/resize until some other state change triggers an update.

Recommended change: move mask management into `PlayerUIView`:
- Add `var cropRect: CGRect?` to `PlayerUIView`; override `layoutSubviews()` to (re)compute the mask path there.
- Keep ONE `CAShapeLayer` instance; mutate `maskLayer.path` only when `cropRect` or `bounds` actually changed (compare last-applied values).
- `updateUIView` just sets `uiView.cropRect = cropRect` (no-op if equal).

Blast radius: `VideoPanelView.swift` only. Verification: Allocations instrument — zero CAShapeLayer churn during playback; rotate device with crop active and confirm mask tracks bounds.

### H4. Scrubbing issues frame-accurate (zero-tolerance) seeks to all 6 players on every drag tick

**Files:** `Coreo/Workspace/TimelineView.swift:309-332` (calls `seek` from `onChanged`), `Coreo/Workspace/WorkspaceViewModel.swift:137-145`
**Status:** VERIFIED. **Confidence: high.**

`scrubDragGesture.onChanged` fires at UI event rate (60-120 Hz on ProMotion) and calls `viewModel.seek(to:)`, which does `player.seek(to:toleranceBefore: .zero, toleranceAfter: .zero)` on every player. Zero-tolerance seeks force exact-frame decode (potentially GOP-walk from the previous keyframe) — across 6 simultaneous decoders this makes scrubbing laggy and hot. AVPlayer coalesces queued seeks, but the tolerance is the dominant cost lever.

Recommended change:
- Add `seek(to:precise:)` to the VM. During `onChanged`, call with `precise: false` -> tolerance `CMTime(seconds: 0.1, preferredTimescale: 600)` (or `.positiveInfinity`); on `onEnded`, issue one final `precise: true` zero-tolerance `seekAll`.
- Same pattern for `SpeedControlView.segmentChip` tap-seek (precise is fine there — single event).
- Optional polish: during scrub only seek the *visible-audio* or reference player precisely and let others follow coarsely, then align all on release.

Blast radius: `WorkspaceViewModel.swift`, `TimelineView.swift`. Verification: on-device scrub feel; Time Profiler shows videodecoder activity drop during drag.

### H5. Players are started with a rate-set loop, not a synchronized host-time start; no drift correction exists

**File:** `Coreo/Workspace/WorkspaceViewModel.swift:552-556` (`playAll`), `121-132` (`togglePlayback` re-seeks then plays)
**Status:** VERIFIED (code); INFERRED (magnitude of skew). **Confidence: medium-high.**

`playAll()` sets `player.rate = playbackRate` sequentially in a loop. Each player starts on its own internal clock; the serial loop introduces a per-player start stagger (typically 5-30 ms across 6 players) on top of seek-completion variance — for a sync-critical app, this is the difference between "frame-locked" and "slightly off." PERFORMANCE.md acknowledges "No periodic drift re-sync" as a known limitation.

Recommended change:
1. **Synchronized start:** after `seekAll` completion (await the seeks — `player.seek` has an async/completion variant), compute one anchor: `let host = CMClockGetTime(CMClockGetHostTimeClock()) + 0.05s`, then for each player call `player.setRate(rate, time: targetItemTime[i], atHostTime: host)`. Requires `automaticallyWaitsToMinimizeStalling = false` (already set, WorkspaceViewModel.swift:404).
2. **Cheap drift watchdog:** in the existing 30 Hz observer, every ~60 ticks compare each player's `currentTime()` against expected (timeline - offset); if |drift| > 0.03 s, micro-correct that player only with a tolerant seek or a brief rate nudge. Skip while a hold/segment rate transition is active.

Blast radius: `WorkspaceViewModel.swift` only (`playAll`, `togglePlayback`, foreground-resume path at 492-505). Verification: record device screen playing a clapperboard video on 2 panels; audio-flash alignment within 1 frame; instrument drift logging for a 3-min playback.

### H6. Entire export pipeline (composition build, speed scaling, instruction build) runs on the MainActor

**File:** `Coreo/Export/ExportEngine.swift:50-55` (`@MainActor static func export`), `417-422` (`performExport` also `@MainActor`)
**Status:** VERIFIED. **Confidence: high.**

`ExportEngine.export` is `@MainActor`. All synchronous segments between `await`s — `buildComposition`'s `insertTimeRange` per track, `applySpeedSegments`' `scaleTimeRange`/`insertEmptyTimeRange`, `buildVideoComposition`'s layout math, disk checks — execute on the main thread while the export progress UI is trying to animate. For 6 tracks + bumper + several speed segments this is easily 100-500 ms of main-thread stalls, plus every `progressHandler` invocation already hops to main anyway via the `@Published` write.

Recommended change: remove `@MainActor` from `export` and `performExport`; the only UIKit touch is `UIApplication.shared.beginBackgroundTask`/`endBackgroundTask`, which should be wrapped in `await MainActor.run { ... }` (or use the `UIApplication` instance API on main). `WorkspaceViewModel.startExport` already calls from a `Task` and writes results back on the main actor (it is `@MainActor` itself), so callers need no change except making `progressHandler` `@Sendable` and dispatching the `exportProgress` write via `MainActor.run` (currently relies on the VM's actor isolation — keep `{ [weak self] p in Task { @MainActor in self?.exportProgress = p } }`).

Blast radius: `ExportEngine.swift`, one closure in `WorkspaceViewModel.startExport`. Verification: main-thread hangs during "Building composition..." phase disappear (Instruments Hangs template).

### H7. Audio sync and Vision smart-crop run sequentially though fully independent

**File:** `Coreo/Import/ImportViewModel.swift:96-140` (sync), `194-204` (`buildProject` runs `computeCropOverrides` after sync completes)
**Status:** VERIFIED. **Confidence: high.**

The import flow awaits `AudioSyncEngine.sync` (~1-2 s), then `buildProject` awaits `SmartCropEngine.computeCropRects` (3-7 s **per video**, concurrent across videos). Total user wait = sum of both. Person detection needs only URLs + dimensions — it does not depend on sync offsets.

Recommended change: in `sync()`, start crop computation immediately alongside sync:
```swift
async let cropTask = computeCropOverrides(for: videos)
let output = try await AudioSyncEngine.sync(videos: inputs)
...
project.cropOverrides = await cropTask
```
Handle the unreliable-video path: `finalizeProject(includeUnreliable: false)` filters videos, so the precomputed dictionary must be re-keyed by surviving indices (crop rects are per-URL, so map URL -> rect and rebuild the index keying after filtering) instead of recomputing detection from scratch (it currently re-runs full detection on the filtered list — also wasteful, ImportViewModel.swift:184).

Blast radius: `ImportViewModel.swift` only. Verification: time from "Sync & Go" to workspace with 4 videos drops by min(syncTime, cropTime); unreliable-removal path no longer re-runs Vision.

### H8. Live hold segments either never trigger (0.01 s footprint vs 33 ms sampling) or deadlock playback when they do

**Files:** `Coreo/Speed/SpeedControlView.swift:388-402` (`durationSeconds: 0.01`), `Coreo/Workspace/WorkspaceViewModel.swift:513-529` (`applyLiveSpeedSegment`), `434-447` (observer only ticks while reference plays)
**Status:** VERIFIED (logic), INFERRED (runtime behavior — needs device). **Confidence: medium-high.**

The 30 Hz periodic observer samples the timeline every ~33 ms (more at >1x rate). A hold segment occupies 0.01 s of timeline, so the sampler usually steps right over it — holds mostly do nothing live. When a tick *does* land inside, `applyLiveSpeedSegment` pauses all players while keeping `isPlaying == true`; but the periodic observer only fires while the reference player's time advances, so `currentTimeSeconds` freezes, the segment rate is never re-evaluated, and playback is stuck until the user toggles. Additionally `SpeedMap(segments:)` + `filter` + `sort` allocates on every tick (line 514 and SpeedSegmentModel.swift:58-65).

Recommended change:
1. Implement live holds with an explicit mechanism: when entering a hold, pause players, start a `Task.sleep(holdDurationSeconds / playbackRate)` then resume players and advance past the segment; or use `addBoundaryTimeObserver` on the reference player at segment start times so entry is exact, not sampled.
2. Cache a sorted segment array in the VM, rebuilt only when `project.speedSegments` changes (didSet), and look up via binary search — removes per-tick allocation/sort.

Blast radius: `WorkspaceViewModel.swift`, `SpeedSegmentModel.swift` (add a precomputed sorted lookup), no model shape change. Verification: unit test: SpeedMap lookup at 10k random times against linear reference; device test: hold at t=5s freezes 2 s then resumes.

### H9. PersonDetector uses deprecated synchronous copyCGImage in a sequential loop; one Vision request per frame

**File:** `Coreo/Crop/PersonDetector.swift:68-104,130-141`
**Status:** VERIFIED. **Confidence: high.**

For a 5-min clip at 2.5 s intervals = 120 frames, each via `imageGenerator.copyCGImage(at:)` — synchronous random-access generation (re-seeks the decoder per call) — followed by a fresh `VNDetectHumanRectanglesRequest` + `VNImageRequestHandler` per frame. This is the 3-7 s/video cost in PERFORMANCE.md.

Recommended change:
1. Use the modern batch API: `imageGenerator.images(for: sampleTimes.map { CMTime(...) })` async sequence — AVFoundation decodes monotonically in one pass instead of 120 random seeks; it also removes the deprecated `copyCGImage` (deprecated iOS 18).
2. Hoist `let request = VNDetectHumanRectanglesRequest()` out of the loop and reuse it (Vision requests are reusable; the model load is shared but request/handler churn isn't free).
3. Consider `maximumSize` 960 px instead of 1280 (human-rect detection is robust at 960; ~45% fewer pixels).
4. Keep the existing `autoreleasepool` + `Task.checkCancellation` per frame.

Blast radius: `PersonDetector.swift` only. Verification: wall-clock detection time per 3-min video before/after (expect ~2-3x faster); crop rect outputs unchanged on test clips.

---

## MEDIUM

### M1. No persistence wiring: every launch redoes FFT sync + Vision crop from scratch

**Files:** `Coreo/Models/CoreoProject.swift:160-185` (save/load implemented), zero call sites in app code (only `CoreoTests/UnitTests/ModelTests.swift:249-276`)
**Status:** VERIFIED. **Confidence: high.**

`CoreoProject.save()`/`load()` are dead code. The most expensive computations in the app (sync ~2 s, crop 3-7 s/video, plus the user's annotations and speed segments) are discarded on process exit. From an efficiency standpoint this is the single largest repeated-work item in the product. Recommended: call `save()` (on a background task) after sync completes and after each mutating workspace action (debounced, e.g., 2 s after last change); on launch, offer "Resume last project" when `load()` succeeds and all `videos[i].localURL` still exist. Note: imported files currently land in `tmp/` (`VideoTransferable`, ImportView.swift:361-377) which the system purges — move imports to Application Support/Documents for persistence to be meaningful. (Data-model scope is allowed per FULL OVERRIDE; no shape change needed, just wiring + import-destination change.)

Blast radius: `ImportView/ImportViewModel`, `WorkspaceViewModel`, `ContentView` (resume path), `VideoTransferable` destination. Verification: kill+relaunch restores project without re-running sync/crop.

### M2. crossCorrelate allocates and returns the full 33 MB correlation array when only the peak is consumed; scales the whole array before the peak search

**File:** `Coreo/Utilities/FFTHelper.swift:127-155,175-189`
**Status:** VERIFIED. **Confidence: high.**

`findOffset` uses only `peakIndex`, `peakValue`, and `correlation.count`. Yet `crossCorrelate` (a) converts the full split-complex result to interleaved (`vDSP_ztoc`, 33 MB array), (b) multiplies the entire array by the scale factor (`vDSP_vsmul` over 8.4 M elements), then (c) finds the peak. Fixes:
- Run `vDSP_maxvi` (and, for robustness against negative-peak conventions, `vDSP_maxmgvi`) **before** scaling and scale only the scalar `peakValue` (`peak * 1/(2N)`), skipping the full-array `vsmul` entirely.
- Provide a peak-only entry point that never materializes `correlation` for callers like `findOffset` (the count is `fftLength`, computable without the array). Keep the array-returning variant for tests.
Combined with C1's in-place product, per-pair allocations drop by ~66 MB.

Blast radius: `FFTHelper.swift`; `AudioSyncTests` may construct expectations on the array — keep `crossCorrelate` for tests, add `findOffset` fast path. Verification: existing tests pass; sync wall-clock drops measurably for 5-min clips.

### M3. AudioSyncEngine extracts reference audio serially before starting the task group

**File:** `Coreo/Sync/AudioSyncEngine.swift:98-105`
**Status:** VERIFIED. **Confidence: high.**

Reference PCM extraction (~0.5-1.5 s for long clips) completes before any other extraction starts. Extract all audios concurrently (bounded — see C1) and then correlate as pairs become available; or at minimum start reference extraction and the first secondary extraction together. Fold into the C1 rework of the task group.

### M4. zrip packed-format bin-0 mishandled in complex multiply (minor accuracy, fix free with vDSP_zvmul)

**File:** `Coreo/Utilities/FFTHelper.swift:104-113`
**Status:** VERIFIED (packing semantics); INFERRED (impact on peak — likely negligible). **Confidence: medium.**

With `vDSP_fft_zrip`, element 0 of the split-complex result packs DC in `realp[0]` and **Nyquist** in `imagp[0]`. The multiply treats `imagp[0]` as the DC imaginary part, cross-contaminating DC and Nyquist bins. Impact on a broadband correlation peak is tiny but nonzero. When applying the `vDSP_zvmul` fix (C2 item 4), handle bin 0 separately: `productReal[0] = refReal[0]*sigReal[0]; productImag[0] = refImag[0]*sigImag[0]` (DC*DC and Nyq*Nyq, both real). Document with a comment.

### M5. Export cancellation does not cancel the AVAssetExportSession; compositor cancel hook is a no-op

**Files:** `Coreo/Export/ExportEngine.swift:442-466`, `Coreo/Workspace/WorkspaceViewModel.swift:346-349`, `Coreo/Export/PanelCompositor.swift:88`
**Status:** VERIFIED (known-deferred, still open). **Confidence: high.**

`cancelExport()` cancels the Swift Task, but `await exportSession.export()` is not cancellation-responsive, so encoding continues to completion in the background (full CPU/energy cost), and the UI dismisses immediately — worst of both. Fix: wrap in `withTaskCancellationHandler(operation: { await exportSession.export() }, onCancel: { exportSession.cancelExport() })`. Implement `cancelAllPendingVideoCompositionRequests` to flag the render queue and `request.finishCancelledRequest()` pending items.

Blast radius: `ExportEngine.swift`, `PanelCompositor.swift`. Verification: cancel mid-export; CPU returns to idle within 1 s (Instruments), temp file removed.

### M6. Export progress uses 10 Hz polling + deprecated export()/progress APIs

**File:** `Coreo/Export/ExportEngine.swift:454-466`
**Status:** VERIFIED. **Confidence: high.**

A `Task` polls `exportSession.progress` every 100 ms (and keeps polling until status flips). On iOS 18+ `AVAssetExportSession.export()` and `.progress` are deprecated in favor of `try await exportSession.export(to: outputURL, as: .mp4)` plus `for await state in exportSession.states(updateInterval: .milliseconds(250))` which yields progress without polling. Migrate; this also removes the manual outputURL/outputFileType assignments and the status-switch in favor of thrown errors.

Blast radius: `performExport` only. Verification: build (API availability), progress UI still animates.

### M7. End bumper regenerated (render + H.264 encode + file IO) on every export

**Files:** `Coreo/Export/ExportEngine.swift:264-292`, `Coreo/Export/EndBumperGenerator.swift:63-125`
**Status:** VERIFIED. **Confidence: high.**

The bumper is deterministic per resolution, yet each export renders 30 frames via CGContext, encodes H.264, writes a temp file, reads it back as an asset, then deletes it. Fixes (either):
1. Cache the generated file at `Library/Caches/coreo_bumper_<w>x<h>.mp4` and reuse (regenerate if missing). One-line cache check; biggest win.
2. Inside generation: the 11 hold frames are identical — append one pixel buffer spanning the hold duration (one `adaptor.append` with later presentation times only for fade frames) instead of 30 appends; reuse a single rendered "text at alpha" CGImage and vary `context.setAlpha` rather than re-drawing text per frame.

Blast radius: `EndBumperGenerator.swift` (+5 lines in ExportEngine). Verification: second export skips bumper generation (log/signpost); bumper visually unchanged.

### M8. Serial asset/metadata loading in export prep

**File:** `Coreo/Export/ExportEngine.swift:142-150` (serial `loadAssets` loop), `165-218` (per-track serial `loadTracks` + separate `load(.naturalSize)` and `load(.preferredTransform)` awaits)
**Status:** VERIFIED. **Confidence: high.**

Six assets load metadata one-by-one; each track then issues two more sequential `load` calls. Use a `withThrowingTaskGroup` to load all assets concurrently, and batch per-track properties in one call: `try await sourceVideoTrack.load(.naturalSize, .preferredTransform)`. Saves a few hundred ms of export startup ("Preparing...").

Blast radius: `ExportEngine.swift`. Verification: export start-to-5% time drops; instruments shows parallel AVAsset IO.

### M9. Trim range is ignored at export: encodes (and bumper-appends) the full timeline

**Files:** `Coreo/Export/ExportEngine.swift` (no reference to `timelineTrimStartSeconds`), `Coreo/Models/CoreoProject.swift:49-52`
**Status:** VERIFIED (also listed in EDGE-CASES.md as known). **Confidence: high.**

Perf angle: a user trimming a 5-min session to 40 s still pays the full 5-min encode (minutes of CPU + 10x file size). Apply trim by inserting only the trimmed source ranges in `buildComposition` (adjust insert times by trim start) or by setting `exportSession.timeRange`. The `timeRange` approach is ~5 lines and composes correctly with the bumper if the bumper is appended *after* computing the trimmed duration — easiest is: set `exportSession.timeRange` to trim range union bumper range only if bumper is inserted at trimmed end; the composition-level approach is cleaner. Coordinate with the correctness lens (this is also a functional gap).

### M10. Document-picker imports run strictly serially

**File:** `Coreo/Import/ImportView.swift:57-67`
**Status:** VERIFIED. **Confidence: high.**

`for url in urls { await viewModel.addVideo(from: url) }` — each `VideoAsset.from(url:)` (track loads + thumbnail generation, ~0.5-1.5 s) completes before the next starts. The photo-picker path is already concurrent (per-item `Task`s, lines 339-354). Use a task group (bounded ~3) and append results on main in completion order; `pendingImports` bookkeeping unchanged. 6-video file import drops from ~6 s to ~2 s.

### M11. PanelCompositor per-frame graph rebuild and single serial render queue

**File:** `Coreo/Export/PanelCompositor.swift:71-94,121-186`
**Status:** VERIFIED (rebuild), INFERRED (serialization cost vs encoder bottleneck). **Confidence: medium.**

Per frame: a new background `CIImage(color:).cropped(...)` (constant per instruction — cache it on the instruction or compositor), per-panel orientation/scale/translate transform chain recomputed (constant per instruction — precompute one `CGAffineTransform` per config and store alongside `PanelConfig`), all requests funneled through one serial queue (AVFoundation issues multiple in-flight requests; CIContext is thread-safe — a concurrent queue or `OperationQueue` with width 2-3 can overlap CI graph build with GPU render). Implementation order: cache bg + precomputed transforms (safe, easy); measure before adding concurrency (encoder is often the bottleneck; don't add complexity blind).

Also noted for cross-lens routing: `PanelConfig.cropRect` (smart-crop/user crop) is carried into the instruction but **never applied** in `compositeFrame` — exported video ignores crop. Correctness bug; fix belongs with this file's rework.

### M12. JSON persistence will be slow/bloated once wired (pretty-printed, sorted, base64 drawings)

**File:** `Coreo/Models/CoreoProject.swift:161-167`
**Status:** VERIFIED (format), INFERRED (cost — depends on drawing sizes). **Confidence: medium.**

`outputFormatting = [.prettyPrinted, .sortedKeys]` inflates encode time and file size; `DrawingAnnotation.drawingData` (PKDrawing blobs, tens-hundreds of KB each) get base64-encoded into the JSON (+33% size, full rewrite per save). When wiring M1: drop prettyPrinted/sortedKeys, save off-main, and either accept base64 (simple) or store drawings as sidecar files referenced by UUID. Also `save()` is synchronous — call from a background task.

### M13. Periodic time observer spawns a new Task per tick and re-dispatches to MainActor from the main queue

**File:** `Coreo/Workspace/WorkspaceViewModel.swift:434-447`
**Status:** VERIFIED. **Confidence: high.**

The observer is installed with `queue: .main`, then the handler wraps the body in `Task { @MainActor in ... }` — an unnecessary allocation + actor hop per tick (30/sec, continuous while playing). Since the closure already runs on the main queue, use `MainActor.assumeIsolated { ... }` (iOS 17+) to run synchronously. Same pattern in the end-of-playback sink (461-469) and lifecycle observers (481-504), which are low-frequency but free to fix identically.

### M14. AVAudioSession activated synchronously at app init and never deactivated

**File:** `Coreo/App/CoreoApp.swift:26-33`
**Status:** VERIFIED (known-deferred, still open). **Confidence: medium.**

`setCategory` + `setActive(true)` run synchronously in `App.init` (blocking launch by ~10-50 ms) and the session stays active for the app's lifetime — interrupting/ducking other audio even on the import screen where nothing plays. Move activation to `WorkspaceViewModel.init` (or first play) on a background task; deactivate with `.notifyOthersOnDeactivation` in `tearDown()`.

### M15. Vision/person-detection results discarded for union-of-all-frames crop (quality AND wasted compute)

**Files:** `Coreo/Crop/SmartCropEngine.swift:44-67,124-134`, consumer `ImportViewModel.swift:208-219`
**Status:** VERIFIED (algorithm); impact INFERRED. **Confidence: medium.**

All 120 frames' rects are unioned into one box. A dancer traversing the stage produces a near-full-frame union -> crop no-ops, meaning the entire detection pass bought nothing. Cheap improvement with the same data: compute the union of per-frame unions' *centers* + a percentile-based extent (e.g., clamp to the 10th-90th percentile of per-frame box edges) so outlier frames don't blow the box up; or compute per-frame unions first and discard frames whose box area > 0.8 (false positives/extreme wides). Keeps API identical (`[CGRect] -> CGRect?`), needs per-frame grouping: change `PersonDetector` to return `[[CGRect]]` (per-frame) — small signature change inside the Crop module.

---

## LOW

### L1. VideoThumbnailView re-decodes JPEG on every body evaluation
**File:** `Coreo/Import/VideoThumbnailView.swift:49-66`. VERIFIED; known-deferred. `UIImage(data:)` per body call during scrolls. Cache decoded image: `@State private var decoded: UIImage?` populated in `.onAppear`/`task`, or precompute `UIImage` once in `ImportViewModel` when the asset is added. Thumbnails are 320 px JPEGs so cost is small but the fix is 5 lines. Confidence: high.

### L2. PencilCanvasRepresentable allocates a new PKInkingTool on every update
**File:** `Coreo/Annotations/AnnotationOverlayView.swift:352-358`. VERIFIED. `updateUIView` sets `uiView.tool = PKInkingTool(...)` unconditionally; compare against current color first. Trivial. Confidence: high.

### L3. LayoutEngine duplicate variants scored redundantly for 6 videos
**File:** `Coreo/Models/LayoutEngine.swift:61-76`. VERIFIED. `case 6` includes `[2,3]` and `[3,2]` which only place 5 rects for 6 videos — they're scored against `min(rects.count, aspectRatios.count)` and can *win* with 5 panels, returning a 5-rect array for 6 videos (callers index-guard, so the 6th video silently doesn't render). Perf is trivial but this is a latent correctness bug worth flagging to the correctness lens; fix: `case 6: return [[3,3],[2,2,2]]`. Confidence: high.

### L4. ImportView error/sync UI state churn re-renders thumbnail row
**File:** `Coreo/Import/ImportView.swift:138-177`. INFERRED, minor. `pendingImports` published changes re-evaluate `populatedState` per import; fine at this scale. No action needed beyond H2-style @Observable migration if done globally. Confidence: medium.

### L5. checkDiskSpace uses a fixed 500 MB floor
**File:** `Coreo/Export/ExportEngine.swift:64,486-492`. VERIFIED. Estimate required bytes from `timelineDuration x target bitrate x 1.5` instead; a 10-min 1080p export can exceed 500 MB while a 30 s one needs far less (currently blocks small exports on nearly-full devices unnecessarily, and under-protects long ones). ~6 lines. Confidence: medium.

### L6. TimelineView trim overlay math runs per tick; coverage bars use `id: \.offset`
**File:** `Coreo/Workspace/TimelineView.swift:136-160,263-304`. VERIFIED, minor. Covered by H2's invalidation-scoping; no separate work needed. `id: \.offset` on enumerated videos is fine since order is stable. Confidence: high.

### L7. EndBumper writer readiness is polled at 10 ms
**File:** `Coreo/Export/EndBumperGenerator.swift:92-94`. VERIFIED. `while !isReadyForMoreMediaData { Task.sleep(10ms) }` — acceptable for 30 frames; `requestMediaDataWhenReady(on:)` is the canonical fix but only worth it if M7 option 1 (caching) is rejected. Confidence: high.

### L8. ShareSheet temp file lingers if user backgrounds before dismissing; tmp imports accumulate
**Files:** `Coreo/Workspace/WorkspaceViewModel.swift:352-357`, `Coreo/Import/ImportView.swift:361-377`. VERIFIED. Exported file is only deleted on sheet dismissal; imported `tmp/` copies (potentially GB) are never deleted when a video is removed from the list (`removeVideo` drops the model only). Add `try? FileManager.default.removeItem` on remove for app-copied files, and a startup sweep of stale `coreo_export_*`/UUID-prefixed tmp files. Confidence: high.

---

## TOP 10 (prioritized one-liners)

1. **C1** Cap sync correlation concurrency at 2 + share FFT setup + scope/reuse buffers — removes the ~1 GB jetsam risk in `AudioSyncEngine`/`FFTHelper`.
2. **C2** Re-apply the four documented-but-missing AudioExtractor/FFT fixes (autoreleasepool, single-copy, reserveCapacity, vDSP_zvmul).
3. **H2** Migrate WorkspaceViewModel to `@Observable` (or split a PlaybackClock) so the workspace stops re-evaluating everything at 30 Hz; cache `panelRects`.
4. **H1** Cache rasterized PKDrawing images per annotation — stop decode+raster on every body evaluation.
5. **H4** Tolerant seeks during scrub, single precise seek on release (6 players currently zero-tolerance at drag rate).
6. **H5** Host-time-synchronized `setRate(_:time:atHostTime:)` start + 2 s drift watchdog for frame-locked multi-player sync.
7. **H7** Run audio sync and Vision crop concurrently at import (`async let`), reuse crop results in the unreliable-removal path.
8. **H6** Take `ExportEngine.export` off the MainActor; wrap only the background-task calls in `MainActor.run`.
9. **H8** Fix live holds (boundary observer + explicit resume) and cache sorted speed segments — removes per-tick alloc/sort and a playback deadlock.
10. **M5+M6** Make cancel actually cancel (`withTaskCancellationHandler` -> `cancelExport()`) and replace 10 Hz progress polling with `states(updateInterval:)`.

Honorable mentions just below the cut: H3 (CAShapeLayer churn in updateUIView), H9 (PersonDetector `images(for:)` batch API), M1 (persistence wiring kills repeated sync/crop), M7 (cache end bumper), M9 (apply trim at export — encode only what's kept).

---

## For JMT (needs device/product judgment)

- **Annotations are invisible during normal playback** (WorkspaceView.swift:50-55 gates `AnnotationOverlayView` behind `isAnnotationMode`, and entering that mode pauses). DESIGN.md calls timed fade-in/out during playback "a core differentiating feature." Flagged to the correctness/UX lens; perf-wise, fixing it makes H1+H2 mandatory first (otherwise 30 Hz PKDrawing rasterization lands on the playback path).
- **Proxy decode for 5-6 panel grids:** 6 simultaneous 1080p/4K decoders for ~180 pt panels is inherently wasteful; `preferredMaximumResolution` doesn't reliably limit local-file decode, so the real fix would be optional import-time proxy transcode (e.g., 720p) with full-res kept for export. Real win on thermals for 6-angle sessions, but it's a product tradeoff (import time + storage) needing your call and on-device measurement.
- **Smart-crop quality** (M15): union-over-all-frames frequently degenerates to full frame, silently wasting the entire Vision pass. Percentile-based extent is my recommended cheap fix, but whether crop should track the dancer over time (animated crop) is a design question.
- On-device profiling pass (Instruments: Allocations during 6-video sync, SwiftUI body counts during playback, Hangs during export prep) should bracket this report's INFERRED magnitudes once xcodebuild is fixed.
