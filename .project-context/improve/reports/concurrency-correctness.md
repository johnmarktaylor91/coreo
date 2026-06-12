# Coreo Improvement Survey — Concurrency & Correctness Lens

Survey agent: concurrency-correctness (1 of 6). Date: 2026-06-11.
Scope: static analysis only (xcodebuild broken on this machine). Every Swift file in
`Coreo/` and `CoreoTests/` was read in full. Line numbers refer to current working-tree state
(single commit `9346ce5` + untracked sources).

Labels: **VERIFIED** = confirmed by reading code paths end-to-end and/or by mathematical
derivation; **INFERRED** = depends on framework runtime behavior or device state that static
analysis cannot fully confirm.

Context note for implementers: the project builds with `SWIFT_VERSION: "5.9"`
(`project.yml:12`) and no strict-concurrency flag, so none of the Sendable/isolation issues
below are currently compiler-enforced. Two existing unit tests would FAIL if the suite were
run today (see findings H1 and C2) — strong evidence the test suite has not been executed
against this code. Do not "fix the code to make tests pass" without reading H1 first.

---

## CRITICAL

### C1. Live hold/freeze segments deadlock playback permanently

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Workspace/WorkspaceViewModel.swift:513-529` (`applyLiveSpeedSegment`)
- `/Users/jmt/projects/coreo/Coreo/Workspace/WorkspaceViewModel.swift:428-448` (`installTimeObserver`)
- `/Users/jmt/projects/coreo/Coreo/Speed/SpeedControlView.swift:388-402` (`addHoldSegment`)

**What's wrong (VERIFIED, three compounding defects):**
1. `applyLiveSpeedSegment` is invoked *only* from the periodic time observer callback. When
   it encounters a hold (`segmentRate == 0`) it pauses all players "but keeps isPlaying true"
   (line 521-523). A paused `AVPlayer` stops firing periodic time observer callbacks
   (they fire only while playback time advances). Result: once a hold triggers, nothing ever
   un-pauses the players. The freeze is permanent. There is no timer to end the hold after
   `holdDurationSeconds`, and `holdDurationSeconds` is never read anywhere in live playback.
2. Even reaching the hold is unreliable: `addHoldSegment` creates the segment with
   `durationSeconds: 0.01` (a 10 ms window) while the observer ticks at 30 Hz (33 ms). The
   `SpeedMap.rate(at:)` lookup usually misses the window entirely, so holds mostly do nothing
   in live playback — and when a tick does land inside, defect 1 makes it stick forever.
3. Recovery is broken too: tapping pause/play resets `currentSegmentRate = nil` and replays,
   but the playhead is still inside the 0.01 s window, so the next tick (if it lands inside)
   re-freezes. `seek(to:)` does not reset `currentSegmentRate` (lines 137-145), so scrubbing
   out of a hold while frozen leaves players paused with `isPlaying == true`.

**Recommended change:**
- Implement live holds with an explicit timer: when the playhead crosses a hold's start,
  pause all players, start a `Task { try await Task.sleep(for: .seconds(holdDurationSeconds)) }`
  (store it; cancel on seek/pause/teardown), then seek players just past `segment.endTimeSeconds`
  and restore `playbackRate * SpeedMap.rate(at: newTime)`.
- Detect crossing, not containment: track previous tick's timeline time, trigger hold when
  `prev < segment.start && current >= segment.start` so the 10 ms window cannot be skipped.
- Reset `currentSegmentRate = nil` inside `seek(to:)` and `seekAll(to:)`.
- Drive the timeline clock during a hold (either freeze `currentTimeSeconds` deliberately and
  resume via the timer, or switch the clock to a `CADisplayLink`/`Timer` source while held).

**Blast radius:** WorkspaceViewModel only (plus a small state struct). No model changes.
**Verification:** unit-test a `HoldScheduler` abstraction (start hold at t, advance fake clock,
assert resume time and post-hold rate); manual test: place hold mid-song, confirm freeze for N
seconds then resumption; scrub across a hold during playback.
**Confidence:** High (API semantics of periodic observers under rate 0 are well established).

---

### C2. 6-video projects: LayoutEngine can return 5 panels — drops a video in preview and renders the 6th video full-frame OVER everything in export

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Models/LayoutEngine.swift:71-72` (`case 6: return [[2, 3], [3, 2], [3, 3], [2, 2, 2]]`)
- `/Users/jmt/projects/coreo/Coreo/Export/ExportEngine.swift:346-347` (fallback `panelRect = CGRect(origin: .zero, size: renderSize)`)
- `/Users/jmt/projects/coreo/Coreo/Workspace/VideoGridView.swift:29` (`if index < rects.count` silently hides extra videos)
- `/Users/jmt/projects/coreo/CoreoTests/UnitTests/LayoutEngineTests.swift:214-222` (test that would catch this)

**What's wrong (VERIFIED, arithmetic checked):** for `videoCount == 6` the candidate list
includes `[2, 3]` and `[3, 2]`, which produce only **5** rects. `totalVisibleArea` then scores
only `min(rects.count, aspectRatios.count) = 5` panels, and 5 large panels frequently outscore
6 small ones. Concretely, for the export render size 1920x1080 with six 16:9 videos:
`[2,3]` scores ~1.72M px^2 vs `[3,3]` ~1.37M and `[2,2,2]` ~1.36M, so **the 5-panel layout
wins in the most common export case**. Consequences:
- Preview (`VideoGridView`): the 6th video is silently not rendered (`index < rects.count`).
- Export (`ExportEngine.buildVideoComposition`): the 6th track gets the fallback
  `panelRect = full renderSize` and, being the *last* `PanelConfig` (PanelCompositor composites
  first→bottom, last→top, `PanelCompositor.swift:131`), the 6th video **covers the entire
  output frame**. A 6-angle export produces a single full-screen video.
- `testSixVideoLayoutReturnsCorrectCount` (container 1000x600, 16:9) also selects `[2,3]`
  by the same arithmetic and would fail — the suite has not been run.

**Recommended change:** `case 6: return [[3, 3], [2, 2, 2]]`. Additionally make
`calculateLayout` defensive: filter candidates where `rowConfig.reduce(0,+) != videoCount`
(assert in debug). In `ExportEngine.buildVideoComposition`, replace the silent full-frame
fallback with a thrown `ExportError.compositionFailed("layout returned N panels for M videos")`
— a wrong-but-loud failure beats silently corrupted output.

**Blast radius:** LayoutEngine (2 lines) + ExportEngine guard. Existing 6-video test passes after fix.
**Verification:** run `LayoutEngineTests.testSixVideoLayoutReturnsCorrectCount`; add a test
asserting `rowConfig` sums equal videoCount for every candidate count 2-6; add an export-level
test that `panelConfigs.count == videoTracks.count` with distinct non-full-frame rects.
**Confidence:** High.

---

### C3. End-bumper source file is deleted before the export session reads it

**File:** `/Users/jmt/projects/coreo/Coreo/Export/ExportEngine.swift:291` (`try? FileManager.default.removeItem(at: bumperURL)` inside `appendEndBumper`)

**What's wrong (INFERRED, strong):** `appendEndBumper` inserts the bumper asset's track into
the composition (Step 4), then immediately deletes the backing `.mp4` from disk. The actual
sample data is only read later, during `AVAssetExportSession.export()` (Step 7).
`insertTimeRange` stores a *reference* to the source track, not the samples. Unless
AVFoundation happens to hold an open file descriptor (not guaranteed — only metadata has been
loaded at that point), the export session will fail (`exportFailed`) or emit black/garbage for
the bumper portion when it tries to open the deleted file. Because `appendEndBumper` "succeeds",
`hasBumper = true` and the instruction timeline still expects bumper content.

**Recommended change:** return `bumperURL` from `appendEndBumper`, and delete it in `export(...)`
*after* `performExport` returns (in a `defer` so failure paths also clean up). Same pattern for
any future intermediate file.

**Blast radius:** ExportEngine only.
**Verification:** integration test on simulator: export a 2-video project, assert exported
asset duration == mainContentDuration + ~1s and that the final second decodes non-black frames.
**Confidence:** Medium-high (failure mode depends on AVFoundation FD behavior; deleting a
source file mid-pipeline is wrong regardless).

---

### C4. Export cancellation does not cancel the AVAssetExportSession; a cancelled export can still pop the share sheet

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Export/ExportEngine.swift:417-482` (`performExport` — no cancellation handler)
- `/Users/jmt/projects/coreo/Coreo/Workspace/WorkspaceViewModel.swift:320-349` (`startExport` / `cancelExport`)

**What's wrong (VERIFIED; also acknowledged in EDGE-CASES.md "Deferred"):**
1. `cancelExport()` cancels the Swift `Task`, but nothing in the pipeline observes cancellation:
   no `Task.checkCancellation()` between steps, and `await exportSession.export()` (the legacy
   API) ignores Swift task cancellation. The session keeps encoding — full CPU/disk cost —
   while the UI already shows "not exporting".
2. When the orphaned export finishes, the task body resumes, `exportSession.status == .completed`,
   and the success branch runs: `exportedVideoURL = url; showShareSheet = true`
   (WorkspaceViewModel:330-332) — the share sheet appears even though the user cancelled
   (possibly minutes earlier, possibly after dismissing the workspace — `tearDown()` cancels
   the task but the same non-propagation applies).
3. The `beginBackgroundTask` expiration handler (ExportEngine:429-435) ends the background task
   but does not cancel the session either, so the OS suspends mid-write.
4. `backgroundTaskID` is a captured mutable local var written from both the actor context and
   the expiration handler — benign today (both on main), but a Swift 6 error.

**Recommended change:** wrap the export in `withTaskCancellationHandler`:
```swift
try await withTaskCancellationHandler {
    await exportSession.export()
} onCancel: {
    exportSession.cancelExport()
}
```
Add `try Task.checkCancellation()` between pipeline steps in `export(...)`. In
`startExport`'s success branch, `guard !Task.isCancelled else { ... cleanup; return }` before
setting `showShareSheet`. Call `exportSession.cancelExport()` from the background-task
expiration handler. Set `exportTask = nil` when it finishes.

**Blast radius:** ExportEngine + WorkspaceViewModel export block.
**Verification:** unit-test the view-model state machine with an injectable fake engine
(cancel mid-flight → assert no `showShareSheet`, temp file removed); manual: cancel a long
export and watch CPU in Instruments.
**Confidence:** High.

---

## HIGH

### H1. FFT lag sign convention: the doc comment and two unit tests are inverted relative to the implementation — and the implementation is the CORRECT one

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Utilities/FFTHelper.swift:158-206` (`findOffset` + doc comment at 160-161)
- `/Users/jmt/projects/coreo/CoreoTests/UnitTests/AudioSyncTests.swift:29-79` (`test_findOffset_knownShift_recoversLag`, `test_findOffset_negativeShift_returnsNegativeLag`)
- Downstream consumers: `/Users/jmt/projects/coreo/Coreo/Sync/AudioSyncEngine.swift:122-124`, `/Users/jmt/projects/coreo/Coreo/Workspace/WorkspaceViewModel.swift:534-540`, `/Users/jmt/projects/coreo/Coreo/Export/ExportEngine.swift:178-185`

**What's wrong (VERIFIED by derivation + impulse example):** the code computes
`IFFT(FFT(reference) * conj(FFT(signal)))` (FFTHelper:104-113). That correlation,
`c[l] = SUM_m r[m+l]*s[m]`, peaks at **negative** lag when `signal` is a *delayed* copy of
`reference`. Sanity check with N=4, r=[1,0,0,0], s=[0,1,0,0] (delayed by 1): peak lands at
index 3 → unwrapped lag = -1. Therefore:
- The doc comment "A positive lag means `signal` is delayed relative to `reference`" is **backwards**.
- `test_findOffset_knownShift_recoversLag` builds a delayed signal (200 zero samples prepended)
  and asserts `lag == +200`; the implementation returns **-200**. The test fails.
  `test_findOffset_negativeShift_returnsNegativeLag` fails symmetrically (+150 vs expected <0).
- **However**, the full pipeline is self-consistent and correct: a camera that physically starts
  recording *later* than the reference has shared audio events appearing *earlier* in its local
  track (signal leads → positive lag) → `offsetSeconds > 0` → matches `SyncResult`'s documented
  semantics ("positive means this video starts after the reference",
  AudioSyncEngine.swift:15-18) → matches the workspace mapping
  `videoSeconds = timelineSeconds - syncOffsets[i]` (WorkspaceViewModel:538) → matches the
  export insert time `max(0, syncOffset - timelineStart)` (ExportEngine:182-185).
  Note that the "delayed signal" in the failing test corresponds physically to a camera that
  started recording 25 ms *before* the reference, for which `offset = -0.025` is correct.

**The danger:** an implementer who runs the failing tests and "fixes" FFTHelper (e.g., swaps
the conjugate to `conj(R)*S`) to satisfy them will silently invert every sync offset and
double the misalignment across preview and export. The fix must go the other way.

**Recommended change:**
1. Fix the `findOffset` doc comment: "A **negative** lag means `signal`'s content is delayed
   relative to `reference` (signal camera started earlier); a **positive** lag means signal's
   content leads (signal camera started later)."
2. Fix the two tests' expectations (`-200`; `> 0` / `+150`).
3. Add an end-to-end semantic test pinned to physical reality: synthesize reference audio and a
   second clip whose recording starts 2.0 s later (i.e., drop the first 2 s of the shared
   waveform), run `FFTHelper.findOffset` and assert `lag/8000 == +2.0 +- tolerance`; then assert
   `CoreoProject` mapping places both videos' shared event at the same timeline coordinate.
   This test makes the convention unbreakable.

**Blast radius:** docs + tests only. Zero production code changes (deliberately).
**Verification:** the new tests.
**Confidence:** High on the math; the failing-test claim is unverifiable until xcodebuild is fixed, flag accordingly.

---

### H2. Exported holds render as a black gap, not a freeze-frame

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Export/ExportEngine.swift:237-244` (`insertEmptyTimeRange` for holds)
- `/Users/jmt/projects/coreo/Coreo/Export/PanelCompositor.swift:132-134` (`sourceFrame(byTrackID:) == nil → continue` → panel = background)

**What's wrong (VERIFIED):** `applySpeedSegments` implements a hold by inserting an *empty*
time range into the composition. During that range no track delivers frames; PanelCompositor
draws only the dark background for every panel, and the single composition audio track goes
silent. The user asked for a freeze-frame; they get `holdDurationSeconds` of near-black video.
(`EDGE-CASES.md` does not list this — it lists holds as functioning via export.)

**Recommended change:** implement a real freeze: for each track, insert the one-frame range at
the hold point and scale it: `track.insertTimeRange(CMTimeRange(start: holdSourceTime,
duration: oneFrame), ...)` then `track.scaleTimeRange(..., toDuration: holdDuration)` — or
equivalently use `composition.scaleTimeRange` on a one-frame window
(`CMTime(value: 1, timescale: exportFPS)`) stretched to `holdDurationSeconds`. Audio during a
hold: insert empty audio range of equal length (intentional silence) so A/V stay aligned.
Apply per-track rather than composition-wide if tracks need different source times (they do:
per-track time = holdTime - timelineStart shifted by each insertTime; since all tracks share
the composition timebase after Step 2, composition-relative `segStart` is the same for all —
keep the existing back-to-front ordering, which is correct).

**Blast radius:** ExportEngine.applySpeedSegments only.
**Verification:** export a project with one 2 s hold; decode frames inside the hold window and
assert non-black + identical to the frame at hold start; assert total duration grows by 2 s.
**Confidence:** High.

---

### H3. End-of-playback / looping keyed to the reference player's item — loops early and cuts off longer videos

**File:** `/Users/jmt/projects/coreo/Coreo/Workspace/WorkspaceViewModel.swift:454-471` (`observeEndOfPlayback`)

**What's wrong (VERIFIED):** the loop trigger is `AVPlayerItemDidPlayToEndTime` on the
*reference* player's item. The timeline end is `max(offset_i + duration_i)` over all videos
(CoreoProject:114-122), which generally belongs to a different video. When the reference video
ends first, all players are immediately seeked back to `timelineStart` — the tail
`[refEnd, timelineEnd]` of the unified timeline is unreachable during playback, even though
`seek` and the timeline UI happily address it. Related: the timeline clock (periodic observer
on the reference player, lines 434-447) stops ticking once the reference ends, so even without
the loop the playhead would freeze while other angles still have content.

Also: the observation captures the item at init and is never re-established (fine today since
items are never replaced; note for future).

**Recommended change:** drive end-of-timeline from the unified clock, not from any single item:
in the periodic tick (or a boundary time observer), when `currentTimeSeconds >= timelineEnd - epsilon`,
loop (`seekAll(to: timelineStart)` + replay). For the clock-source problem, either (a) pick the
video with maximal `offset+duration` as the *clock* player (independent of sync reference), or
(b) keep a host-time-based master clock (`CMTimebase`/`CACurrentMediaTime` anchored on play) so
the timeline advances regardless of which players are active. Option (b) is the robust fix and
also enables the inactive-panel "Starts in 0:04" countdowns to keep updating.

**Blast radius:** WorkspaceViewModel playback core. Medium-size change; pairs naturally with H9.
**Verification:** project where reference (highest audio bitrate) is the *shortest* clip;
assert playhead reaches timelineEnd and the longer angle plays out before looping.
**Confidence:** High.

---

### H4. A single no-audio video makes the entire sync fail (regression vs documented behavior)

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Import/ImportViewModel.swift:104-106` (passes all videos to sync)
- `/Users/jmt/projects/coreo/Coreo/Sync/AudioSyncEngine.swift:108-133` (any extraction failure throws and kills the TaskGroup)
- `/Users/jmt/projects/coreo/Coreo/Sync/AudioExtractor.swift:52-55` (`.noAudioTrack` throw)
- Contrast: `/Users/jmt/projects/coreo/EDGE-CASES.md` ("No-audio videos broke sync pipeline | ImportViewModel.swift | Filter to audio-bearing videos for sync, flag no-audio as unreliable" — listed as FIXED)

**What's wrong (VERIFIED):** `VideoAsset.from` deliberately allows audio-less videos
(`audioBitrate = 0`, VideoAsset.swift:109-119), but `ImportViewModel.sync()` feeds every video
into `AudioSyncEngine.sync`. For a no-audio clip, `AudioExtractor.extractPCM` throws
`.noAudioTrack`; the throwing task group rethrows; the user gets "Sync failed: Failed to extract
audio from video N..." and no project at all. EDGE-CASES.md claims this was fixed by filtering;
the filter does not exist in the code. (The documented error string "At least 2 videos with
audio are needed for automatic sync." also doesn't exist; `SyncError.insufficientVideos` says
"At least 2 videos are required for audio sync.")

**Recommended change:** in `ImportViewModel.sync()`, partition videos into audio-bearing
(`audioBitrate > 0` or `audioSampleRate > 0`) and silent. Run `AudioSyncEngine.sync` on the
audio-bearing subset (require >= 2, else `syncError` with the documented message), assign
offset 0 to silent videos and append them to `unreliableVideos` so the existing alert flow
handles them. Keep an index mapping subset→original so `output.offsets` land on the right
videos. Alternative (deeper): make `AudioSyncEngine.sync` tolerate per-video failure by
returning a per-video `Result`, reserving thrown errors for the reference itself failing.

**Blast radius:** ImportViewModel.sync + small AudioSyncEngine change if the alternative is chosen.
**Verification:** unit test with a fake extractor (inject via protocol) where one clip throws
`.noAudioTrack`: assert sync succeeds, silent clip flagged unreliable with offset 0.
**Confidence:** High.

---

### H5. Smart crop is never applied in export, and the live-preview crop is geometrically wrong

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Export/PanelCompositor.swift:34` (`PanelConfig.cropRect` — declared, **never read** in `compositeFrame`, lines 98-187)
- `/Users/jmt/projects/coreo/Coreo/Workspace/VideoPanelView.swift:171-190` (`applyCropMask`)

**What's wrong (VERIFIED):**
1. Export: `ExportEngine` carefully threads `project.cropOverrides?[index]` into
   `PanelConfig.cropRect` (ExportEngine:356), but `compositeFrame` ignores it entirely. The
   Vision person-detection pipeline (PersonDetector → SmartCropEngine → cropOverrides) has zero
   effect on exported output.
2. Live preview: `applyCropMask` multiplies the normalized crop rect by the *view's* bounds and
   masks the layer. But the crop rect is normalized to the *video frame*, and with
   `.resizeAspectFill` the video frame does not coincide with the view bounds (it overflows on
   one axis). The mask therefore selects the wrong region, and instead of zooming into the crop
   it merely blanks out part of the panel. The mask is also computed from `view.bounds` during
   `updateUIView` and never updated on layout changes (rotation/panel resize) — `PlayerUIView`
   has no `layoutSubviews` override.

**Recommended change:**
- Export: in `compositeFrame`, after orienting the image, apply
  `image = image.cropped(to: cropRectInImageCoords)` where
  `cropRectInImageCoords = CGRect(x: crop.minX * extent.width, y: (1 - crop.maxY) * extent.height,
  w: crop.width * extent.width, h: crop.height * extent.height)` (flip Y: stored crop is
  top-left-origin per SmartCropEngine, CIImage is bottom-left), then run the existing
  aspect-fill math against the cropped extent.
- Preview: drop the mask approach. Compute scale/offset so the crop region aspect-fills the
  panel: scale = max(panelW/(cropW*videoW_in_view), panelH/(cropH*videoH_in_view)), translate so
  crop center maps to panel center — i.e., transform the `AVPlayerLayer` (or wrap it in a
  container and set `playerLayer.frame` larger + offset), recomputed in `layoutSubviews`.
  This makes preview and export agree.

**Blast radius:** PanelCompositor (small, well-isolated), VideoPanelView/PlayerUIView.
**Verification:** unit-test the crop→CIImage rect mapping function with the same fixtures as
`AudioSyncTests`' SmartCrop tests; visual device check that preview matches export framing.
**Confidence:** High on "unused in export" and "stale mask"; Medium-high on the preview
geometry critique (depends on intended UX, but current behavior cannot be the intent).

---

### H6. PersonDetector uses VNDetectHumanRectanglesRequest with default `upperBodyOnly == true` — crops cut dancers' legs off

**File:** `/Users/jmt/projects/coreo/Coreo/Crop/PersonDetector.swift:130-141` (`detectHumans`)

**What's wrong (VERIFIED against Vision API defaults; INFERRED for output impact):**
`VNDetectHumanRectanglesRequest()` defaults to `upperBodyOnly = true` (torso+head boxes). For
a choreography app, the union of upper-body boxes excludes legs/feet; SmartCropEngine's 15%
padding will not reliably recover them. The resulting auto-crop tends to frame dancers from the
waist up — the opposite of what dance footage needs.

**Recommended change:** `request.upperBodyOnly = false` (and consider pinning
`request.revision` for determinism across OS versions). Re-evaluate `defaultPadding` (0.15)
after the change.

**Blast radius:** one line + possible padding retune.
**Verification:** sample dance video on device; assert detected boxes' height fraction
increases; visual check feet are inside crop.
**Confidence:** High that the flag is wrong; Medium on magnitude of UX impact.

---

### H7. Project persistence is dead code: `save()`/`load()` are never called, and stored video URLs point at purgeable temp files

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Models/CoreoProject.swift:146-186` (save/load — zero call sites outside tests; verified by grep)
- `/Users/jmt/projects/coreo/Coreo/Import/ImportView.swift:361-377` (`VideoTransferable` copies picks into `temporaryDirectory`)
- `/Users/jmt/projects/coreo/Coreo/Import/DocumentPickerView.swift:24-27` (`asCopy: true` → copies land in tmp/Inbox)

**What's wrong (VERIFIED):**
1. No code path ever calls `project.save()` or `CoreoProject.load()`. Annotations, speed
   segments, sync offsets, crop overrides — all work is lost the moment the workspace is
   dismissed or the process dies. (ModelTests test save/load, but the app never uses them.)
2. Even if persistence were wired up: `VideoAsset.localURL` is (a) an *absolute* path — the app
   container UUID changes across reinstalls/updates, breaking every stored URL — and (b) inside
   `tmp/`, which iOS purges under disk pressure, breaking projects even within one install.

**Recommended change (data-model change, in scope per FULL OVERRIDE):**
- On import, move video copies to `Documents/Videos/<asset-id>.<ext>` (or Application Support),
  not tmp.
- Store `localURL` as a *relative* filename and resolve against the current Documents directory
  at runtime (custom Codable or a computed `resolvedURL`). Keep a migration shim that tries the
  absolute path if the relative file is missing.
- Call `save()` on meaningful mutations (annotation CRUD, speed segment changes, audio source,
  layout/crop overrides — debounced) and `load()` at app start with a "Resume project?" path,
  validating file existence per EDGE-CASES.md's deferred item.

**Blast radius:** VideoAsset, CoreoProject, ImportView/ImportViewModel, app startup flow.
This is the largest item in this report; it is also the difference between a demo and a product.
**Verification:** round-trip test with relative URL resolution; kill-and-relaunch manual test;
simulate container move by rewriting the stored prefix.
**Confidence:** High.

---

### H8. `setPlaybackRate` / `playAll` ignore the active speed segment — user rate change un-freezes holds and misapplies rates until the next segment boundary

**File:** `/Users/jmt/projects/coreo/Coreo/Workspace/WorkspaceViewModel.swift:150-157, 552-556, 513-529`

**What's wrong (VERIFIED):** `applyLiveSpeedSegment` only writes player rates when the
*segment* rate changes (`segmentRate != currentSegmentRate`). If the user changes the global
`playbackRate` while inside a 0.5x segment, `setPlaybackRate` sets `player.rate = rate`
directly — dropping the segment multiplier — and the cached `currentSegmentRate` prevents the
next tick from correcting it until the playhead crosses a segment boundary. If the user changes
rate while frozen in a hold (players paused, `currentSegmentRate == 0`), `setPlaybackRate`
sets a nonzero rate and breaks the freeze. `playAll()` (used by resume, loop, foreground
restore) likewise applies bare `playbackRate`; `togglePlayback` papers over it by resetting
`currentSegmentRate = nil`, but the foreground/loop paths do not.

**Recommended change:** centralize effective-rate computation:
`func applyEffectiveRate() { let seg = SpeedMap(segments: project.speedSegments).rate(at: currentTimeSeconds); if seg == 0 { pauseAll() } else { for p in players { p.rate = playbackRate * seg } } }`
and call it from `setPlaybackRate`, `playAll`, and the tick (tick keeps the change-detection
cache, but the cache must store the *pair* (segmentRate, playbackRate)).

**Blast radius:** WorkspaceViewModel.
**Verification:** unit-test effective-rate computation; manual: set 2x global inside a 0.5x
segment, confirm players run at 1.0x.
**Confidence:** High.

---

### H9. Multi-player sync: playback starts before seeks complete, and there is no drift correction at all

**File:** `/Users/jmt/projects/coreo/Coreo/Workspace/WorkspaceViewModel.swift:121-132 (`togglePlayback`), 543-556 (`seekAll`/`playAll`), 428-448 (tick)`

**What's wrong (VERIFIED for the race; INFERRED for drift magnitude):**
1. On resume, `togglePlayback` calls `seekAll(...)` (fire-and-forget, tolerance-zero seeks are
   *slow* — they decode from the previous keyframe) and then immediately `playAll()`. Players
   begin playing from their *pre-seek* positions and snap when their individual seeks land —
   at different times per player. Every resume starts visibly out of sync for up to several
   hundred ms, which is precisely the moment users are watching for alignment.
2. There is no periodic re-sync. 2-6 independent `AVPlayer`s (independent timebases) drift over
   minutes — typically tens of ms over a 3-5 min routine, worse with
   `automaticallyWaitsToMinimizeStalling = false` and rate changes. DESIGN intent (multi-angle
   frame-accurate comparison) needs a correction loop.
3. Rate changes are applied in a `for` loop — not atomically across players (small but
   systematic skew at every speed change; each `player.rate =` takes effect independently).

**Recommended change:**
- Make resume async: `await withTaskGroup` over `player.seek(to:toleranceBefore:.zero, toleranceAfter:.zero)`
  (the async/completion variant), and only then set rates.
- Add drift correction in the periodic tick: for each non-reference player compute
  `expected = currentTimeSeconds - syncOffsets[i]`, `actual = player.currentTime().seconds`;
  if `abs(actual - expected) > threshold` (suggest 1 frame, ~33 ms; resync with
  tolerance-zero seek; hysteresis to avoid seek storms).
- The robust endgame (pairs with H3): drive all players from one `CMTimebase` master clock
  via `AVPlayer.setRate(_:time:atHostTime:)` so starts and rate changes are sample-accurate
  and drift is structurally impossible. `automaticallyWaitsToMinimizeStalling = false` is
  already set, which is the prerequisite.
**Blast radius:** WorkspaceViewModel playback core. The `setRate(_:time:atHostTime:)` variant
is a bigger refactor; the seek-then-play + drift-check variant is incremental and low-risk.
**Verification:** instrumented build logging per-player `currentTime` deltas each second over a
5-minute playback; assert max drift < 1 frame.
**Confidence:** High for the resume race; Medium-high for drift (device-dependent).

---

## MEDIUM

### M1. SpeedMap.addSegment duplicates segment IDs when splitting — breaks Identifiable and removeSegment

**File:** `/Users/jmt/projects/coreo/Coreo/Speed/SpeedSegmentModel.swift:97-110`

**What's wrong (VERIFIED):** when a new segment overlaps the middle of an existing one, the
existing segment is split into left and right parts that both retain the original `id`. Two
`Identifiable` elements with the same id: `ForEach(viewModel.project.speedSegments)`
(SpeedControlView:152, TimelineView:171) exhibits undefined behavior (duplicate-ID warnings,
wrong diffing); `removeSegment(id:)` deletes *both* halves; the "tap an existing segment"
editing path (SpeedControlView:354-360) resolves ambiguously.
**Recommended change:** assign `id: UUID()` to `leftPart` and `rightPart` (requires making
`id` a `var` or re-constructing the struct). Add a unit test: add overlapping segment → all
resulting IDs unique.
**Blast radius:** model + trivial; no UI change.
**Confidence:** High.

### M2. FFT packed-spectrum multiply corrupts the DC/Nyquist bins

**File:** `/Users/jmt/projects/coreo/Coreo/Utilities/FFTHelper.swift:104-113`

**What's wrong (VERIFIED, math):** `vDSP_fft_zrip` packs DC into `real[0]` and Nyquist into
`imag[0]`. The elementwise complex multiply at `i == 0` treats (DC, Nyquist) as one complex
number, producing garbage in both bins (`productReal[0] = DC_r*DC_s + Nyq_r*Nyq_s`, etc.).
After the inverse FFT this spreads a small constant+alternating error across the whole
correlation array. For zero-mean audio it rarely moves the argmax, but it biases `peakValue`
(and hence confidence) and is simply wrong.
**Recommended change:** special-case index 0: `productReal[0] = refReal[0]*sigReal[0];
productImag[0] = refImag[0]*sigImag[0]` (packed-format conjugate multiply), loop from `i = 1`.
Also consider replacing the scalar loop with `vDSP_zvmul`/`vDSP_zvcmul` (conjugate variant)
for speed — same special-casing still required.
**Verification:** unit test correlating signals with a DC offset (e.g., +0.5 bias) and assert
peak index unchanged vs a brute-force O(N^2) reference correlation on a small fixture.
**Confidence:** High.

### M3. Inverse-FFT scaling is off by 2x — confidence scores are inflated and the 0.3 threshold doesn't mean what it says

**File:** `/Users/jmt/projects/coreo/Coreo/Utilities/FFTHelper.swift:142-144, 192-204`; threshold at `/Users/jmt/projects/coreo/Coreo/Sync/AudioSyncEngine.swift:75`

**What's wrong (VERIFIED, math):** with vDSP zrip conventions (forward = 2x DFT each, inverse
= N x IDFT), the product of two forward transforms carries 4x, and the inverse adds N: total
4N. The code divides by `2N` (comment claims "vDSP's inverse FFT leaves a factor of 2*N"),
leaving correlation values at 2x truth. `confidence = min(peak/sqrt(E_s*E_r), 1.0)` then
saturates: identical aligned signals compute 2.0, clamped to 1.0. Every confidence in (0.15..0.5]
true-value reports as (0.3..1.0], i.e., the effective reliability threshold is 0.15, not 0.3,
and the clamp destroys resolution among good matches.
**Recommended change:** `scale = 1.0 / Float(fftLength * 4)`. Then re-validate the 0.3
threshold against real footage (it will flag more videos unreliable — that may actually match
the original intent).
**Verification:** test: `findOffset(signal: s, reference: s)` must return confidence ~1.0
*without* hitting the clamp (assert `0.95 < c <= 1.0` after removing/inflating the clamp in a
debug assertion); compare against brute-force normalized correlation.
**Confidence:** Medium-high (vDSP scaling conventions are notoriously fiddly; the proposed test
settles it empirically — write the test first).

### M4. Confidence denominator uses full-signal energies — partially overlapping clips get systematically low confidence

**File:** `/Users/jmt/projects/coreo/Coreo/Utilities/FFTHelper.swift:192-204`

**What's wrong (VERIFIED conceptually):** `peak / sqrt(E_signal * E_reference)` is the
Cauchy-Schwarz bound only for fully overlapping signals. If clip B shares just 30 s of a 3 min
reference, the peak is bounded by the *overlap* energy while the denominator uses full energies
— confidence is crushed toward 0 and perfectly good syncs get flagged "unreliable" (alert
fatigue → users learn to tap "Include Anyway", destroying the feature's value).
**Recommended change:** normalize by overlap: given lag `l`, compute energies of
`reference[max(0,l) ..< min(Nr, Ns+l)]` and the corresponding signal slice (two `vDSP_dotpr`
calls on subranges) and use those in the denominator. Or implement proper NCC via running-sum
arrays. Combine with M3.
**Verification:** fixture: 30 s overlap of 3 min clips, assert confidence > 0.6.
**Confidence:** High concept, Medium on threshold numbers.

### M5. Sync pipeline: unbounded concurrency, ~100 MB per correlation, detached tasks that ignore cancellation

**Files:**
- `/Users/jmt/projects/coreo/Coreo/Sync/AudioSyncEngine.swift:108-141` (TaskGroup, all pairs at once)
- `/Users/jmt/projects/coreo/Coreo/Utilities/FFTHelper.swift:21-156` (no cancellation points; large allocations)
- `/Users/jmt/projects/coreo/Coreo/Sync/AudioExtractor.swift:69-110` (`Task.detached`)
- `/Users/jmt/projects/coreo/Coreo/Crop/PersonDetector.swift:76-101` (`Task.detached`)

**What's wrong (VERIFIED):**
1. For 3-minute clips at 8 kHz, each cross-correlation allocates ~2^22-2^23-float arrays
   (padded x2, split halves x4, product x2, correlation) — roughly 100 MB transient per pair.
   The task group launches **all 5** non-reference correlations concurrently → ~0.5 GB spike on
   top of 6 imported videos. Jetsam risk on older devices. (PERFORMANCE.md does not cover this.)
2. `Task.detached` in AudioExtractor severs structured cancellation: cancelling the sync task
   group does NOT cancel the detached readers. `try Task.checkCancellation()` inside
   PersonDetector's detached closure checks the *detached* task, which nobody cancels — it's
   decorative. FFT correlation has no cancellation points at all. Navigating away during sync
   leaves the full pipeline running to completion.
3. `AudioExtractor`: if `extractFloats` throws mid-loop, `reader.cancelReading()` is never
   called (relies on deinit).
4. Swift 6 note: the detached closures capture `AVURLAsset`/`AVAssetTrack`/`[String: Any]`
   (non-Sendable) — will not compile under strict concurrency.

**Recommended change:** replace `Task.detached` with plain `await withCheckedThrowingContinuation`
on a utility queue OR keep async but inherit cancellation (`Task` is unnecessary — the
functions are already async and off-main when called from the group; the detach only obscures
things). Throttle the group: process correlations with `maxConcurrent = 2` (standard
"add 2, then add-as-you-drain" TaskGroup pattern). Add `try Task.checkCancellation()` before
each FFT stage and inside the extraction read loop. Call `reader.cancelReading()` in a defer.
Free `referenceAudio` ASAP / consider capping correlation window (e.g., first 90 s of each
clip is plenty for offset finding and cuts memory 4x — algorithmic choice, surface to JMT).
**Blast radius:** Sync subsystem; no behavior change for outputs.
**Verification:** Instruments allocations run on 6x3min import; cancellation test with a
fake-slow extractor asserting prompt termination.
**Confidence:** High.

### M6. finalizeProject(includeUnreliable: false) builds a project with a wrong referenceVideoIndex and un-normalized offsets

**File:** `/Users/jmt/projects/coreo/Coreo/Import/ImportViewModel.swift:148-188`

**What's wrong (VERIFIED):** after filtering out unreliable videos, the new project is built
with `referenceVideoIndex: 0`, but `filteredOffsets` are still relative to the *original*
reference (which may now sit at any index, or — since results only cover non-reference videos —
is always kept, but its filtered index is not 0 in general). This violates the documented
invariant `syncOffsets[referenceVideoIndex] == 0` (CoreoProject.swift:33). The timeline math
itself tolerates any offset origin, but WorkspaceViewModel uses `referenceVideoIndex` to choose
the clock player and the loop trigger (see H3), and `AudioSyncOutput.audioSourceIndex` /
`referenceIndex` semantics silently diverge from the array they index.
**Recommended change:** after filtering, locate the original reference's new index
`newRef = filteredVideos.firstIndex(of original reference)`; set `referenceVideoIndex: newRef`;
re-normalize `filteredOffsets = filteredOffsets.map { $0 - filteredOffsets[newRef] }`.
Also enforce the invariant in `sanitizeIndices()` (shift all offsets so
`syncOffsets[referenceVideoIndex] == 0`).
**Verification:** unit test: 3 videos, reference index 1, video 2 unreliable & removed →
assert invariant holds.
**Confidence:** High.

### M7. Import/sync interleaving races: videos mutated during sync; auto-sync can skip late additions

**Files:** `/Users/jmt/projects/coreo/Coreo/Import/ImportView.swift:54-76, 339-354`; `/Users/jmt/projects/coreo/Coreo/Import/ImportViewModel.swift:96-140, 194-204`

**What's wrong (VERIFIED logic-race; all on MainActor so no data race):**
1. `sync()` captures `inputs` from `videos`, then `await`s for seconds. `addVideo` can append
   (or `removeVideo` remove) during the await. `buildProject(from:)` then pairs the *current*
   `self.videos` with the *stale* `output.offsets` — wrong counts and wrong pairing.
   Downstream guards (`videos.count == syncOffsets.count` in CoreoProject) make the timeline
   silently degenerate (returns 0) rather than crash.
2. `onChange(of: pendingImports)` triggers sync whenever the count hits 0 — but if a new import
   completes while `isSyncing == true`, `canSync` is false, the trigger is dropped, and there is
   no retry: the UI shows no sync button (it appears only when `syncError != nil`), leaving the
   user stuck with an unsynced extra video.
**Recommended change:** snapshot `let videosAtSyncStart = videos` at the top of `sync()` and
build the project from the snapshot; reject/queue `addVideo` while `isSyncing` (disable add UI),
or set a `needsResync` flag consumed when sync completes. Make the post-import auto-sync logic
explicit in the view model (`importCompleted()`), not an `onChange` side effect in the view.
**Verification:** unit test: start sync with 2 videos (slow fake engine), add a 3rd mid-flight,
assert resulting project pairs offsets correctly and a resync is scheduled.
**Confidence:** High.

### M8. TimelineView: drawing math and gesture math use different widths — playhead/coverage misaligned by up to 16 pt

**File:** `/Users/jmt/projects/coreo/Coreo/Workspace/TimelineView.swift:44-87 (drawing, full `geometry.size.width` inside `.padding(.horizontal, 8)` content), 309-332 (gesture uses `width - 16` and `x - 8`)`

**What's wrong (VERIFIED):** `videoCoverageBars`, `speedSegmentOverlays`, and `scrubArea` are
laid out inside a VStack with `.padding(.horizontal, 8)` but compute x-positions against the
*unpadded* width. The drag gesture (attached to the outer ZStack) correctly maps with the
padded width. Net effect: drawn playhead/coverage positions are stretched ~2% relative to
touch mapping; at the timeline's right edge the playhead draws ~16 pt past where the finger
maps, and a drag to a marker doesn't land on it.
**Recommended change:** pass `width - 16` into all drawing helpers (or remove the inner
padding and use one width everywhere).
**Verification:** UI test or preview snapshot: seek to `timelineEnd`, assert playhead x ==
content width.
**Confidence:** High.

### M9. Negative timeline coordinates display as 0:00 and current/total time mix coordinate systems

**Files:** `/Users/jmt/projects/coreo/Coreo/Utilities/TimeFormatting.swift:17-18, 38-39` (negative clamped to 0); `/Users/jmt/projects/coreo/Coreo/Workspace/PlaybackControlsView.swift:36-44`; `/Users/jmt/projects/coreo/Coreo/Workspace/TimelineView.swift:245-257`

**What's wrong (VERIFIED):** `timelineStartSeconds = min(syncOffsets)` is frequently negative
(any video starting before the reference). `currentTimeSeconds` is an absolute timeline
coordinate, so early in playback it is negative; formatters clamp negatives to 0 → the clock
sits at "0:00" for the first |timelineStart| seconds, then starts moving. Meanwhile
PlaybackControls shows `current (absolute) / timelineDuration (span)` and TimelineView's right
label shows `timelineEnd` (absolute) — three different conventions on screen.
**Recommended change:** display elapsed-from-start everywhere:
`TimeFormatting.format(currentTimeSeconds - timelineStart)` and totals as
`timelineDuration`. Keep absolute coordinates internal-only.
**Verification:** unit test the displayed strings for a project with offsets [-5, 0].
**Confidence:** High.

### M10. PanelCompositor.cancelAllPendingVideoCompositionRequests is a no-op — cancelled exports can hang or stall

**File:** `/Users/jmt/projects/coreo/Coreo/Export/PanelCompositor.swift:88-94`

**What's wrong (VERIFIED vs AVVideoCompositing contract):** AVFoundation requires pending
async requests to be finished (typically via `finishCancelledRequest()`) when
`cancelAllPendingVideoCompositionRequests` is called (e.g., on session cancel — relevant once
C4 is fixed). Requests already dispatched to `renderQueue` will still render; that's tolerable,
but requests must not be left unfinished.
**Recommended change:** track in-flight requests (`pendingRequests` set guarded by the same
serial `renderQueue`, or an `OSAllocatedUnfairLock`), and in cancel: dispatch sync to
`renderQueue` finishing each with `finishCancelledRequest()` and setting a `cancelled` flag
that `compositeFrame` checks before rendering.
**Blast radius:** PanelCompositor only. Required for C4's `cancelExport()` to terminate promptly.
**Confidence:** Medium-high.

### M11. ExportEngine is @MainActor end-to-end; progress closure is a non-Sendable escaping callback — heavy work pinned to main, Swift 6 incompatible

**File:** `/Users/jmt/projects/coreo/Coreo/Export/ExportEngine.swift:50-55, 417-422`

**What's wrong (VERIFIED):** `export(...)` and `performExport(...)` are `@MainActor`. The
non-annotated helpers (`buildComposition`, `appendEndBumper`, etc.) run off-main, but every
`await` resumes the pipeline on the main actor, and composition/instruction building plus
progress polling all execute on main. `progressHandler: @escaping (Double) -> Void` crossing
into a `@MainActor` static from arbitrary contexts is a strict-concurrency error in Swift 6.
**Recommended change:** make the engine `nonisolated` (it touches UIApplication only in
`performExport` — isolate just `beginBackgroundTask`/`endBackgroundTask` calls with
`await MainActor.run`), and type the callback `@MainActor @Sendable (Double) -> Void`. The
caller (WorkspaceViewModel:325-327) already assumes main delivery.
**Blast radius:** ExportEngine signatures; WorkspaceViewModel call site unchanged semantically.
**Verification:** compiles under `SWIFT_STRICT_CONCURRENCY = complete` (see M15); Tier-1 tests.
**Confidence:** High.

### M12. Scrub seek storm: tolerance-zero seeks on every drag tick for every player, no coalescing

**Files:** `/Users/jmt/projects/coreo/Coreo/Workspace/TimelineView.swift:309-332`; `/Users/jmt/projects/coreo/Coreo/Workspace/WorkspaceViewModel.swift:137-145`

**What's wrong (VERIFIED):** the drag gesture calls `viewModel.seek(to:)` per touch sample
(60-120 Hz), each issuing N tolerance-zero seeks. The plain `seek(to:toleranceBefore:after:)`
does supersede in-flight seeks, so there is no stale-result bug today (the no-completion
variant can't apply out of order), but tolerance-zero forces keyframe-distance decodes per
sample → laggy scrubbing on 4K/HEVC, hot device, and the players visibly straggle. There is
also no terminal precise seek guarantee beyond the last sample.
**Recommended change:** standard coalescing: during drag use
`toleranceBefore/After = CMTime(value: 1, timescale: 10)` or chase-pattern (`isSeekInFlight`
flag + `pendingSeekTarget`, issue next seek from the completion of the previous); on
`.onEnded`, issue one final tolerance-zero `seekAll`. Keep frame-stepping (if added later)
tolerance-zero.
**Confidence:** High (perf), Low (correctness risk today).

### M13. EndBumperGenerator can spin forever if the writer fails

**File:** `/Users/jmt/projects/coreo/Coreo/Export/EndBumperGenerator.swift:90-114`

**What's wrong (VERIFIED):** `while !writerInput.isReadyForMoreMediaData { try await Task.sleep(...) }`
has no exit for `writer.status == .failed` — a failed writer never becomes ready, so the loop
polls forever (export hangs at 20-30%, with `hasBumper` never resolving). Cancellation would
break it only if someone cancels (see C4 — they currently can't).
**Recommended change:** inside the wait loop, `if writer.status == .failed { throw BumperError.writingFailed(...) }`;
also bound the wait (e.g., 5 s) defensively.
**Confidence:** High.

### M14. No AVAudioSession interruption / route-change handling — `isPlaying` desyncs from reality on phone calls

**File:** `/Users/jmt/projects/coreo/Coreo/App/CoreoApp.swift:26-33`; WorkspaceViewModel lifecycle block (476-505 covers only background/foreground)

**What's wrong (VERIFIED absence):** an incoming call / Siri / alarm interrupts the session;
AVPlayers pause; `isPlaying` stays true; the periodic observer stops ticking (paused players);
UI shows pause-icon state mismatch and the unified clock freezes. On `.ended` with
`.shouldResume` nothing resumes.
**Recommended change:** observe `AVAudioSession.interruptionNotification` in
WorkspaceViewModel: on `.began` mirror the background path (record `wasPlaying`, set
`isPlaying = false`); on `.ended` + `.shouldResume`, `seekAll` + `playAll`.
**Confidence:** High.

### M15. Swift 5.9 / no strict concurrency: latent isolation bugs are invisible; turn the checker on

**File:** `/Users/jmt/projects/coreo/project.yml:12` (`SWIFT_VERSION: "5.9"`, no `SWIFT_STRICT_CONCURRENCY`)

**What's wrong (VERIFIED):** the codebase uses modern concurrency heavily but compiles with no
data-race checking. Known violations the checker would flag: AudioExtractor/PersonDetector
detached captures (M5), ExportEngine progressHandler (M11), `backgroundTaskID` capture (C4.4),
`@unchecked Sendable` on PanelCompositor (its `ciContext` is confined to `renderQueue` —
actually fine, but deserves a comment justifying the `@unchecked`).
**Recommended change:** set `SWIFT_STRICT_CONCURRENCY: complete` (warnings) in project.yml as a
first step; fix warnings; then consider `SWIFT_VERSION: 6.0`. Do this *after* the functional
fixes above so the diff noise doesn't mix.
**Confidence:** High.

---

## LOW

### L1. sanitizeIndices doesn't restore the `syncOffsets[referenceVideoIndex] == 0` invariant; `timelineEndSeconds` seeds maxEnd at 0
`/Users/jmt/projects/coreo/Coreo/Models/CoreoProject.swift:91-103, 114-122`. After index clamps,
the reference's offset may be nonzero (see M6); `maxEnd` starting at 0 returns 0 instead of the
true (negative) end for degenerate all-negative-offset cases. Seed with `-.greatestFiniteMagnitude`
and normalize offsets in sanitize. VERIFIED; cosmetic-to-minor.

### L2. AnnotationCompositor (currently dead) has three latent integration bugs — document before re-enabling
`/Users/jmt/projects/coreo/Coreo/Export/AnnotationCompositor.swift` (entire file unused — Step 6
in ExportEngine is a no-op, ExportEngine.swift:120-125):
(a) keyTimes are normalized against the *unmodified* timeline duration; once speed
segments/holds change the composition duration, every annotation's time range is wrong — the
time mapping must be composed with the speed remap (build a timeline→output-time function from
the applied segments and map annotation start/end through it);
(b) drawing rasterization uses `image(from: CGRect(origin:.zero, size: renderSize))` while
strokes were authored in container-point space (~390 pt wide) — exports would render drawings
tiny in a corner; rasterize from the authoring bounds and scale;
(c) the `renderSize.width / 375` font/line scale assumes a 375 pt container and ignores aspect
mismatch between the preview grid and export render size. Also note
AVVideoCompositionCoreAnimationTool is incompatible with the custom compositor (already
documented) — annotations must be drawn inside PanelCompositor (CIImage overlay or pre-rendered
per-annotation CGImages with opacity from `TimedAnnotation.opacity(at:)`, which is the single
source of truth the preview already uses). INFERRED (feature disabled). Also
`ExportProgressView.statusText` shows "Adding annotations..." for a feature that doesn't run
(`ExportProgressView.swift:121-135`).

### L3. Dead/orphaned features: trim and AnnotationTimeRangeControl
`timelineTrimStartSeconds/Duration` are rendered (TimelineView:263-304) but nothing sets them
and export ignores them (grep-verified). `AnnotationTimeRangeControl.swift` has zero call sites.
Either wire them up or delete; half-wired features are where corruption bugs breed. VERIFIED.

### L4. exportTask retains self strongly; tearDown depends entirely on onDisappear
`WorkspaceViewModel.swift:320-343, 576-596`. The export task captures `self` strongly (fine —
keeps VM alive for the export) but combined with C4 a cancelled-but-running export pins the VM
and players for minutes. After C4 fix this self-resolves. The "no deinit" design means a missed
`onDisappear` (rare NavigationStack edge cases) leaks the time observer and notification
observers; consider an additional safety `deinit` that removes the time observer via a
nonisolated captured token pair (player+token captured weakly into a nonisolated cleanup
closure) once on Swift 6 / isolated deinit. VERIFIED design note.

### L5. observeEndOfPlayback uses `.receive(on: RunLoop.main)` — not delivered during touch tracking
`WorkspaceViewModel.swift:459-470`. RunLoop.main scheduling defers during `.tracking` mode
(active scrubs/gestures); use `DispatchQueue.main` (or keep, given H3 removes this observer).
VERIFIED nuance.

### L6. ExportError equality hack
`WorkspaceViewModel.swift:599-606` defines a private `static ==` without `Equatable`
conformance; the `catch let error as ExportError where error == .cancelled` works but is
fragile. Use `if case .cancelled = error` pattern matching instead. VERIFIED style/correctness.

### L7. Photo-picker import order is nondeterministic and failures are silent
`ImportView.swift:339-354`: N parallel Tasks append in completion order, so the panel order can
differ from the user's selection order; `try? await item.loadTransferable` swallows errors
(user sees nothing). Process sequentially (or index the results) and surface failures via
`syncError`. VERIFIED minor UX-correctness.

### L8. scaleTimeRange pitch-shifts audio in speed segments
`ExportEngine.swift:245-258` scales the audio track along with video; no
`audioTimePitchAlgorithm` is set on the export session. Set
`exportSession.audioTimePitchAlgorithm = .spectral` (or mute scaled ranges) — product decision.
VERIFIED behavior, severity depends on intent.

### L9. Cancelled/failed exports can strand temp files
`coreo_export_*.mp4` is removed on failure paths inside `performExport`, but with C4 (cancel
doesn't propagate) the success-path file persists if the share sheet never shows (e.g., user
left the workspace). `cleanUpExportedFile` runs only on sheet dismissal. Add a startup sweep of
`tmp/coreo_export_*` and `coreo_bumper_*`. VERIFIED minor.

### L10. Per-tick allocations in the hot path
`applyLiveSpeedSegment` constructs `SpeedMap` + filter + sort 30x/sec
(WorkspaceViewModel:513-515); `AnnotationOverlayView.drawingView` re-decodes and re-rasterizes
`PKDrawing` on every `currentTimeSeconds` change (AnnotationOverlayView:283-292). Cache the
sorted segments (invalidate on mutation) and cache rasterized drawings keyed by annotation id +
size. VERIFIED; perf-leaning but belongs in any correctness pass touching these files.

---

## TOP 10 (priority order)

1. **C2** — Fix `LayoutEngine` 6-video candidates (`[[3,3],[2,2,2]]`) + make ExportEngine throw instead of full-frame fallback: 6-angle exports are currently garbage.
2. **C1** — Rebuild live hold handling (timer-driven, crossing detection, reset cache on seek): holds either no-op or freeze the app's playback forever.
3. **C4 (+M10, M13)** — Make export cancellation real (`withTaskCancellationHandler` → `cancelExport()`, checkCancellation between steps, no share sheet after cancel, writer-failure exit in bumper loop, finish cancelled compositor requests).
4. **H1** — Resolve the FFT lag sign convention: fix the doc + 2 inverted tests, keep the implementation, add an end-to-end physical-convention test so nobody "fixes" sync backwards.
5. **C3** — Don't delete the bumper file until the export session finishes.
6. **H2** — Export holds as real freeze-frames (scaleTimeRange on a one-frame window), not `insertEmptyTimeRange` black.
7. **H3 + H9** — Unified clock not tied to the reference item: loop at `timelineEnd`, await seeks before resume, add per-tick drift correction (or master `CMTimebase`).
8. **H4** — Filter no-audio videos out of sync and flag them unreliable (restores documented behavior).
9. **H7** — Wire up persistence: copy imports to Documents, store relative URLs, call save/load.
10. **H5 + H6** — Make smart crop actually do something: apply cropRect in PanelCompositor, fix preview crop geometry, set `upperBodyOnly = false`.

Also strongly recommended in the same wave: M1 (duplicate segment IDs), M3+M4 (confidence
scaling/normalization — changes user-facing reliability warnings), M6 (filtered-project
reference invariant), M8/M9 (timeline alignment + time display), M15 (turn strict concurrency on
last, as cleanup).

---

## For JMT (needs device / product judgment)

- **Drift tolerance:** how much inter-angle drift is acceptable before forced resync? I
  recommend 1 frame (33 ms) with hysteresis; tighter makes scrubbing/jitter worse. Device test needed.
- **Hold audio:** during a freeze-frame, silence (recommended) or looped audio? Affects H2/C1.
- **Sync window cap (M5):** correlating only the first ~90 s of each clip cuts sync memory ~4x
  and is usually sufficient for offset finding — but breaks if cameras started >90 s apart. OK?
- **Confidence threshold (M3/M4):** after fixing the 2x inflation and overlap normalization,
  0.3 needs re-tuning on real multi-phone footage; current value is effectively 0.15.
- **Speed-segment audio pitch (L8):** chipmunk vs pitch-corrected vs muted for 0.25-2x ranges.
- **Preview crop UX (H5):** zoom-to-crop in panels (preview matches export) vs no visible crop
  in preview; current masked behavior is neither.
- The status text "Adding annotations..." shows during export while annotation export is
  disabled — leaving it sets a user expectation the export doesn't meet.
