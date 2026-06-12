# Coreo Robustness & Edge Cases Survey

Survey agent lens: error handling, weird media, sync failure modes, lifecycle, persistence, export robustness.
Date: 2026-06-11. Static analysis only (xcodebuild unavailable). Baseline commit: f23d5fa.

Severity legend: Critical = data loss / hang / total feature breakage on plausible input.
High = wrong output, crash on edge input, or unrecoverable user-facing failure.
Medium = degraded/incorrect behavior in narrower circumstances or latent traps.
Low = polish, hygiene, theoretical.

Each finding labels claims VERIFIED (read in code, structurally certain) or INFERRED (requires
runtime/API-doc confirmation; reasoning given).

---

## CRITICAL

### C1. Project persistence is completely unwired — every session is lost on app exit

- Refs: `Coreo/Models/CoreoProject.swift:161-185` (save/load exist), `Coreo/App/ContentView.swift:13-31`, `Coreo/App/CoreoApp.swift:16-21`, `Coreo/Workspace/WorkspaceViewModel.swift:20`
- What's wrong (VERIFIED): `CoreoProject.save()` and `CoreoProject.load()` are dead code. The only call sites in the repo are `CoreoTests/UnitTests/ModelTests.swift:249,251,276`. `ContentView` never calls `load()` on launch; nothing ever calls `save()` — not on annotation add, speed segment add, audio-source change, backgrounding, or workspace dismissal. All annotations, sync offsets, speed segments, and crop overrides evaporate when the app is killed (which iOS does freely to backgrounded apps). EDGE-CASES.md's "Persistence" section ("Save is atomic", "Corrupted JSON -> load() returns nil") describes behavior that can never trigger. Additionally, tapping the workspace back button (`WorkspaceView.swift:112-117`) discards the project with no confirmation.
- Recommended change: (1) Autosave `viewModel.project` on every mutation (debounced, e.g. 500ms after last change) and on `didEnterBackground`/`tearDown()`. (2) On launch, if `CoreoProject.load()` returns a project, offer "Resume last project" (validate referenced files exist first — see M2). (3) Move imported videos out of tmp into Documents/`<projectID>/` so reload is possible (see H11). (4) Add a `schemaVersion: Int` field NOW, before any saved file exists in the wild, with a lenient decoder.
- Blast radius: ContentView, CoreoApp, WorkspaceViewModel, ImportViewModel, CoreoProject; no algorithm changes.
- Verification: unit test save-mutate-load roundtrip; manual: annotate, kill app, relaunch, project restored.
- Confidence: high.

### C2. One audio-less video aborts the entire sync — direct regression vs EDGE-CASES.md's documented fix

- Refs: `Coreo/Import/ImportViewModel.swift:105`, `Coreo/Sync/AudioSyncEngine.swift:108-141`, `Coreo/Sync/AudioExtractor.swift:52-55`, EDGE-CASES.md:30-31,47-48,83
- What's wrong (VERIFIED): EDGE-CASES.md claims "No-audio videos broke sync pipeline -> Filter to audio-bearing videos for sync, flag no-audio as unreliable" and an error message "At least 2 videos with audio are needed for automatic sync." Neither exists in code. `ImportViewModel.sync()` maps ALL videos (`videos.map { (url: $0.localURL, audioBitrate: $0.audioBitrate) }`) into `AudioSyncEngine.sync`, which extracts PCM from every video inside a *throwing* task group. The first `AudioExtractionError.noAudioTrack` (or any per-video extraction failure) rethrows and aborts the whole group, so a single screen-recording-without-mic or muted clip blocks the user's entire project with "Sync failed: Failed to extract audio from video N". `VideoAsset.from` deliberately admits no-audio videos (`VideoAsset.swift:107-119`), so the import screen accepts them and then sync always fails.
- Recommended change: In `ImportViewModel.sync()`, partition videos into audio-bearing (`audioBitrate > 0`) and silent. Require >= 2 audio-bearing (else `syncError = "At least 2 videos with audio are needed for automatic sync."`). Sync only the audio-bearing subset (preserving an index map back to the full array), assign offset 0 + `isReliable=false` to silent videos and route them through the existing `unreliableVideos` alert. Also: inside `AudioSyncEngine`, catch per-video extraction failure and degrade that one video to (offset 0, confidence 0, unreliable) rather than throwing — one corrupt audio track should not kill the other five.
- Blast radius: ImportViewModel, AudioSyncEngine; no model changes.
- Verification: unit test `AudioSyncEngine`-level behavior via a seam, or extract the partition logic into a testable pure function; manual: import 2 normal + 1 muted video, sync completes with warning.
- Confidence: high.

### C3. Live-playback "hold" freezes the app's playback forever (or never triggers)

- Refs: `Coreo/Workspace/WorkspaceViewModel.swift:513-529` (applyLiveSpeedSegment), `:428-448` (installTimeObserver), `Coreo/Speed/SpeedSegmentModel.swift:58-65`, `Coreo/Speed/SpeedControlView.swift:388-402`
- What's wrong (VERIFIED structurally): `applyLiveSpeedSegment` is only invoked from the periodic time-observer callback, which only fires while the reference player is advancing. When the playhead enters a hold segment (`rate == 0`), the code pauses all players "but keeps isPlaying true". With players paused, the periodic observer stops ticking, so `applyLiveSpeedSegment` is never called again and nothing ever schedules resumption after `holdDurationSeconds`. Playback is permanently frozen with the UI in "playing" state; only manual scrubbing/pausing escapes. Compounding it, `SpeedControlView.addHoldSegment` gives holds a 0.01s timeline footprint while the observer ticks at ~33ms intervals, so the playhead usually jumps clean over the window and the hold never fires at all. Either way, the DESIGN.md behavior ("panels freeze for the specified duration, then playback resumes") does not exist in live playback.
- Recommended change: When a hold is entered, pause players, record `holdUntil = Date() + holdDurationSeconds`, and schedule a `Task { try await Task.sleep(...) }` (cancellable, stored) that resumes players at `playbackRate * postHoldRate` and advances `currentTimeSeconds` past the segment end. Detect segment entry by interval-crossing (did playhead cross `startTimeSeconds` between two ticks), not point-in-range, so a 0.01s footprint still triggers. Cancel the pending resume task in `togglePlayback`, `seek`, and `tearDown`.
- Blast radius: WorkspaceViewModel only.
- Verification: unit test on an extracted hold-scheduler; manual: place a 2s hold, play through it, playback resumes after 2s.
- Confidence: high (structure), medium (exact observed symptom — needs device run).

### C4. EDGE-CASES.md / PERFORMANCE.md claim fixes that are absent from the code — doc/code divergence sweep needed

- Refs: EDGE-CASES.md:15 vs `Coreo/Sync/AudioExtractor.swift:90-99` (no reserveCapacity at all, claimed "guard finite duration, fallback 8192"); PERFORMANCE.md "High Fixes" 4/5/6/7 vs `AudioExtractor.swift:89-110` (no autoreleasepool, still double-copies via `Data` then `Array` at `:138-155`) and `Coreo/Utilities/FFTHelper.swift:110-113` (scalar multiply loop, claimed `vDSP_zvmul`); PERFORMANCE.md "Medium Fixes" 6 vs `Coreo/Sync/AudioSyncEngine.swift` (no `Task.checkCancellation` anywhere in it); EDGE-CASES.md:31/83 vs finding C2.
- What's wrong (VERIFIED): At least six concrete fixes that both docs record as DONE are not present in the current source (the Sync/FFT/AudioExtractor cluster looks rewritten or reverted after the 2026-03-17 sprint). The docs are the project's safety ledger; right now they assert crash fixes and memory fixes that do not exist, which will misdirect future agents (including the Codex implementers reading this).
- Recommended change: Treat every "Fixed" row in EDGE-CASES.md and PERFORMANCE.md as unverified. Re-verify each against code (this report covers most), re-apply the genuinely missing ones (autoreleasepool + reserveCapacity + single-copy in AudioExtractor, vDSP_zvmul in FFTHelper, checkCancellation in AudioSyncEngine, audio-bearing sync filter), and update both docs to match reality in the same PR.
- Blast radius: docs + AudioExtractor + FFTHelper + AudioSyncEngine.
- Verification: grep-based checklist per claimed fix; commit updates docs and code together.
- Confidence: high.

### C5. Sync memory blow-up: full-length FFT correlation, all videos concurrently, no cap

- Refs: `Coreo/Utilities/FFTHelper.swift:29-45` (fftLength = next pow2 of combined length; ~8 arrays of fftLength/halfLength floats live simultaneously), `Coreo/Sync/AudioSyncEngine.swift:108-133` (unbounded `withThrowingTaskGroup` — all non-reference videos correlate at once), `Coreo/Sync/AudioExtractor.swift:90-99` (whole track into memory, no duration cap)
- What's wrong (VERIFIED allocation math, INFERRED jetsam): For two 10-minute clips at 8 kHz, combined length 9.6M -> fftLength 2^24 = 16.8M floats. Live buffers: 2 padded inputs (134 MB), 4 split-complex halves (134 MB), 2 product halves (67 MB), correlation (67 MB) ~= 400 MB per pair — and with 6 videos, 5 pairs run CONCURRENTLY (~2 GB), on top of extracted PCM held for all videos. iOS will jetsam the app mid-sync for long clips. EDGE-CASES.md says "Video duration ... No hard limit"; PERFORMANCE.md itself lists "Unbounded concurrent correlations (cap at 2)" as deferred and its "~40 MB peak" claim assumes the cap exists. There is also no upfront free-RAM or duration check.
- Recommended change: (1) Cap correlation concurrency at 2 (semaphore pattern inside the task group or chunked `addTask`). (2) Cap correlation input length: correlate only the first N minutes (e.g. 3 min = 1.44M samples -> fftLength 2^22 shared across pair, ~100 MB peak) — sync offset is recoverable from any overlapping window; document the assumption that recordings overlap within the first N minutes, or fall back to full-length only when the windowed pass is unreliable. (3) Free extracted reference PCM eagerly after group completes. (4) Add `Task.checkCancellation()` between videos.
- Blast radius: AudioSyncEngine, FFTHelper, AudioExtractor. Sync-algorithm change is explicitly in scope per survey brief.
- Verification: unit test that windowed correlation recovers a known offset; Instruments allocation trace on-device with 2x10-min clips.
- Confidence: high (math), medium (exact device threshold).

---

## HIGH

### H1. 7+ videos: import is uncapped and LayoutEngine returns [] -> blank workspace, garbage export

- Refs: `Coreo/Import/ImportView.swift:48-53` (photosPicker `maxSelectionCount: 6` — per invocation only, repeatable), `Coreo/Import/DocumentPickerView.swift:28` (`allowsMultipleSelection = true`, no count limit), `Coreo/Import/ImportViewModel.swift:65-74` (no cap in `addVideo`), `Coreo/Models/LayoutEngine.swift:29` (`guard videoCount >= 1, videoCount <= 6 else { return [] }`), `Coreo/Workspace/VideoGridView.swift:28-29` (`index < rects.count` -> renders nothing), `Coreo/Export/ExportEngine.swift:343-347` (panelRect fallback = full renderSize for every track)
- What's wrong (VERIFIED): Nothing prevents importing 7+ videos (two picker batches, or 7 files at once from Files). With count > 6, `calculateLayout` returns an empty array: the workspace grid renders ZERO panels (every index fails `index < rects.count`), and export silently stacks all videos full-frame on top of each other (only the last-composited is visible). DESIGN.md says "Warn if >6 ... Do not hard-block, but UI may degrade" — current behavior is total breakage, not degradation.
- Recommended change: Enforce a hard cap of 6 in `ImportViewModel.addVideo` (reject with `syncError = "Coreo supports up to 6 angles. Remove a video to add another."`) and disable the add tile at 6. That is simpler and safer than making LayoutEngine handle N>6; keep the LayoutEngine guard as a backstop but make `VideoGridView`/`ExportEngine` fall back to a simple N-row layout if rects.count != videoCount rather than rendering nothing.
- Blast radius: ImportViewModel, ImportView, VideoGridView, ExportEngine fallback.
- Verification: unit test `addVideo` cap; LayoutEngineTests case for count 7 documenting the contract.
- Confidence: high.

### H2. Removing a video while sync is in flight corrupts the project (index race)

- Refs: `Coreo/Import/ImportViewModel.swift:79-83` (removeVideo has no isSyncing guard), `:96-140` (sync awaits with `videos` re-read after await at :109-124, :194-203), `Coreo/Import/ImportView.swift:143-147` (thumbnail X always enabled), `Coreo/Models/CoreoProject.swift:115` (count-mismatch guard makes timelineEnd 0)
- What's wrong (VERIFIED race window): `sync()` captures inputs, awaits `AudioSyncEngine.sync`, then re-reads `self.videos` to build the project. The remove button stays active during the multi-second sync, so the user can mutate `videos` mid-await. Result: `output.offsets.count != videos.count` -> `buildProject` constructs a project whose `syncOffsets` length mismatches `videos`; `timelineEndSeconds` then returns 0 and the workspace timeline/coverage/seek logic all collapse (duration 0). Unreliable-video indices also point at the wrong files in the alert.
- Recommended change: Disable removal (and addVideo) while `isSyncing` (guard in the view model methods, not just UI), or snapshot `videos` at sync start and build the project exclusively from the snapshot, discarding the result if `videos` changed (generation counter).
- Blast radius: ImportViewModel, ImportView.
- Verification: unit test — start sync against a stub engine that suspends, remove a video, assert sync result discarded/blocked.
- Confidence: high.

### H3. Export cancellation neither stops work nor prevents a concurrent second export

- Refs: `Coreo/Workspace/WorkspaceViewModel.swift:346-349` (cancelExport sets isExporting=false immediately), `:312-343` (startExport guards only on isExporting), `Coreo/Export/ExportEngine.swift:51-138` (no `Task.checkCancellation()` between steps), `:465` (`await exportSession.export()`), EDGE-CASES.md:72 ("Task cancellation cancels the Swift Task but not the underlying AVAssetExportSession")
- What's wrong (VERIFIED + project-doc-confirmed): `cancelExport()` cancels the Swift Task, but ExportEngine never checks cancellation during steps 1-6 (asset loading, composition, bumper generation), and per the project's own notes the in-flight `AVAssetExportSession` keeps encoding. Because `isExporting` flips false instantly, the user can immediately start a SECOND export while the first still runs -> two sessions competing for codec/disk, duplicate temp files never cleaned (the cancelled session's outputURL is orphaned since the cancelled Task's cleanup code never runs).
- Recommended change: (1) Thread the session out: have `performExport` register the session (e.g. via an actor or a `@MainActor` static weak ref) and `cancelExport()` call `exportSession.cancelExport()`. (2) Sprinkle `try Task.checkCancellation()` between pipeline steps and wrap export in `withTaskCancellationHandler { } onCancel: { session.cancelExport() }`. (3) Only set `isExporting=false` when the export task actually finishes (await it), and delete `outputURL` on every non-completed path.
- Blast radius: ExportEngine, WorkspaceViewModel.
- Verification: manual on device — cancel at 60%, confirm CPU drops and tmp contains no `coreo_export_*` files; attempt double export.
- Confidence: high.

### H4. Holds export as a black flash, not a freeze-frame

- Refs: `Coreo/Export/ExportEngine.swift:237-244` (`insertEmptyTimeRange` for holds), `Coreo/Export/PanelCompositor.swift:131-134` (`sourceFrame(byTrackID:)` nil -> `continue` -> panel = background)
- What's wrong (VERIFIED structurally): A hold is implemented as an empty time range inserted into every track. During that range no track delivers frames, so PanelCompositor paints pure background — the exported video shows N seconds of near-black instead of frozen frames. This contradicts DESIGN.md ("all panels freeze on that frame") and silently diverges from whatever the user previewed.
- Recommended change: Implement holds by extracting the frame at the hold point per track and either (a) using `scaleTimeRange` on a 1-frame range stretched to holdDuration (simplest: scale a minimal range `[t, t+1/30]` to holdDuration — AVFoundation will repeat the held frame), or (b) keeping the empty range but caching the last-seen pixel buffer per trackID in PanelCompositor and re-compositing it when sourceFrame is nil within main content. Option (a) is more robust (also fixes audio gap alignment) — note `scaleTimeRange` affects all tracks including audio (audio silence during hold is expected per spec).
- Blast radius: ExportEngine.applySpeedSegments (option a) or PanelCompositor (option b).
- Verification: export with one 2s hold; scrub the output — frame held, not black.
- Confidence: high.

### H5. End-of-playback loop keyed to the reference player — early loop cuts off longer angles

- Refs: `Coreo/Workspace/WorkspaceViewModel.swift:454-471` (observeEndOfPlayback on reference item only), `:428-448` (timeline clock = reference player), `Coreo/Sync/AudioSyncEngine.swift:96` (reference = highest audio bitrate, NOT longest)
- What's wrong (VERIFIED): The reference video is chosen by audio bitrate, so it is frequently not the longest on the unified timeline. When the reference item plays to end, ALL players loop back to timelineStart even though other angles still have content; and because the timeline clock is the reference player's periodic observer, `currentTimeSeconds` can never advance beyond the reference video's end — the timeline tail (DESIGN: "spans ... to the latest end point") is unreachable in live playback (only visible by scrubbing, where panels render but time never advances on play).
- Recommended change: Drive the loop (and ideally the clock) from the video whose `syncOffset + duration == timelineEndSeconds`. Minimal fix: observe `AVPlayerItemDidPlayToEndTime` for the longest-ending item; better: keep the periodic observer on a player that is guaranteed active (or switch observers when the current clock player ends — pick the latest-ending video as the clock owner at setup).
- Blast radius: WorkspaceViewModel (setup/observer paths).
- Verification: import 2 clips where the higher-bitrate clip is 10s shorter; play; verify playback reaches the longer clip's tail before looping.
- Confidence: high.

### H6. Smart crop is silently dropped from exports — preview/export mismatch

- Refs: `Coreo/Export/PanelCompositor.swift:34` (PanelConfig.cropRect declared), `:98-187` (compositeFrame never reads `config.cropRect`), `Coreo/Export/ExportEngine.swift:356` (cropRect populated), `Coreo/Workspace/VideoPanelView.swift:144-190` (live playback honors crop)
- What's wrong (VERIFIED): The export pipeline carries `cropOverrides` all the way into PanelConfig and then ignores it: compositeFrame aspect-fills the FULL frame into the panel. Users see a person-cropped preview in the workspace but get the wide uncropped framing in the exported file. Classic silent-wrong-output.
- Recommended change: In `compositeFrame`, when `config.cropRect != nil`, convert the normalized top-left-origin crop rect to CIImage coordinates (y-flip within `extent`), `image = image.cropped(to: cropInImageCoords)`, then run the existing aspect-fill math against the cropped extent. Guard zero-width/height crop (clamped crops can degenerate — `SmartCropEngine.clampToUnitRect` can return width/height 0) by falling back to full frame.
- Blast radius: PanelCompositor only.
- Verification: export a project with a known cropOverride; compare frame against preview; add a unit test for the rect-mapping math (pure function — extract it).
- Confidence: high.

### H7. Photo-library import failures are silently swallowed (iCloud-offloaded videos vanish)

- Refs: `Coreo/Import/ImportView.swift:339-354` (`try? await item.loadTransferable ... else { return }`), `:361-377` (VideoTransferable copy can also throw -> wrapped in same try?)
- What's wrong (VERIFIED): `handlePhotoPickerSelection` uses `try?` + `guard else return`. Any failure — iCloud-offloaded original that fails/times out downloading, out-of-disk during the copy, DRM, network airplane-mode — produces NOTHING: no error banner, the video simply never appears, `pendingImports` decrements, and auto-sync may proceed with fewer videos than the user selected. This is the single most likely real-world import failure (iCloud Photos "Optimize Storage" is on by default).
- Recommended change: Replace `try?` with do/catch; on failure set `viewModel.syncError = "Couldn't load \(itemDescription): \(error.localizedDescription)"`. Distinguish slow iCloud downloads with a progress affordance if cheap (PhotosPickerItem gives no progress; at minimum keep the pending spinner accurate and report failures). Suppress auto-sync when any item in the batch failed (let the user retry/remove).
- Blast radius: ImportView.
- Verification: device test with an offloaded video in airplane mode — error banner appears, no silent drop.
- Confidence: high.

### H8. No audio-session interruption or route-change handling — phone call leaves UI in zombie "playing" state

- Refs: `Coreo/App/CoreoApp.swift:26-33` (category set, nothing else), `Coreo/Workspace/WorkspaceViewModel.swift:476-505` (only didEnterBackground/willEnterForeground observed; no `AVAudioSession.interruptionNotification`, no `routeChangeNotification`)
- What's wrong (VERIFIED absence): On a phone call / Siri / alarm, the system pauses all AVPlayers (rate -> 0). `isPlaying` stays true, the periodic observer stops, the play button shows "pause", and the freeze looks identical to the C3 hold-hang. After interruption ends, nothing resumes (interruption-ended options are not observed). Unplugging headphones (route change `.oldDeviceUnavailable`) similarly pauses players with no state reconciliation.
- Recommended change: In WorkspaceViewModel, observe `AVAudioSession.interruptionNotification`: on `.began` -> mirror the didEnterBackground path (record wasPlaying, pauseAll, isPlaying=false); on `.ended` with `.shouldResume` -> re-seek + resume. Observe `routeChangeNotification` for `.oldDeviceUnavailable` -> pause + isPlaying=false. Both flow through existing pause/seek helpers.
- Blast radius: WorkspaceViewModel.
- Verification: device test — incoming call during playback; UI reflects paused state, playback resumes cleanly.
- Confidence: high.

### H9. No recovery path when sync is wrong: manual nudge (in DESIGN.md) is unimplemented; offsets are unvalidated

- Refs: DESIGN.md "Manual nudge fallback" (per-video +/-2s slider) — `grep nudge|fineTune` over `Coreo/` has zero hits; `Coreo/Sync/AudioSyncEngine.swift:122-131` (offset accepted regardless of magnitude); `Coreo/Import/ImportViewModel.swift:122-134` (only include/remove choices)
- What's wrong (VERIFIED absence): When cross-correlation picks a garbage peak (different background noise per camera, music starting late, clapperless recordings), the user's only options are "Include Anyway" (broken alignment, no way to fix) or "Remove" (lose the angle). The DESIGN-promised fine-tune slider does not exist anywhere. Worse, an absurd offset (e.g. +9 minutes for a 30s clip — peak in noise) is accepted silently if confidence happens to clear 0.3; such a panel will show "Starts in 9:00" forever and stretch the unified timeline to nonsense.
- Recommended change: (1) Add per-video offset nudge UI in the workspace edit tools (slider or stepper, +/-2s at 0.01s, writing `project.syncOffsets[i]` and re-seeking). (2) Sanity-gate engine output: if `abs(offset) > min(signalDuration, referenceDuration)` (zero actual overlap), zero it and mark unreliable. (3) Persist nudges via C1.
- Blast radius: WorkspaceViewModel + new small view; AudioSyncEngine output validation.
- Verification: unit test offset gate; manual nudge round-trip.
- Confidence: high.

### H10. Thumbnail failure blocks import of otherwise-playable videos

- Refs: `Coreo/Models/VideoAsset.swift:131-138` (`catch { throw .thumbnailGenerationFailed }`), `:53` (`thumbnailData` is already Optional), `Coreo/Import/VideoThumbnailView.swift:49-66` (placeholder path already exists)
- What's wrong (VERIFIED): `AVAssetImageGenerator.image(at:)` failures (some HDR/Dolby Vision content, esoteric codecs, frame-decode hiccups at the 25% timestamp) abort the whole import even though playback may work fine. The model and the thumbnail view both already support `thumbnailData == nil` with a film-icon placeholder — the throw is gratuitous.
- Recommended change: On thumbnail failure, set `thumbnailData = nil` and proceed (optionally retry once at time 0). Keep the error reserved for genuinely unreadable files (which the duration/track guards already catch).
- Blast radius: VideoAsset.from only.
- Verification: unit-testable by injecting a generator failure via a seam, or accept manual testing; behavior change is strictly permissive.
- Confidence: high.

### H11. Imported videos live in tmp/ — purgeable by iOS, never cleaned up, no disk check

- Refs: `Coreo/Import/ImportView.swift:361-377` (VideoTransferable copies to `temporaryDirectory`), `Coreo/Import/DocumentPickerView.swift:24-27` (`asCopy: true` -> system copy into tmp/Inbox), `Coreo/Import/ImportViewModel.swift:79-83` (removeVideo doesn't delete the file)
- What's wrong (VERIFIED): Every imported video is a full copy in `tmp` (DESIGN.md said reference-don't-copy). Three consequences: (1) iOS may purge tmp under disk pressure — even mid-session-suspension, breaking the project on resume, and definitively breaking any future persistence (C1); (2) removed/failed imports leak their copies (import 6x 4K videos twice = multi-GB of orphans until the system purges); (3) no free-space check before copying — importing near-full disk fails opaquely inside `FileRepresentation`.
- Recommended change: Copy imports into `Documents/<projectID>/media/` (excluded from iCloud backup via `isExcludedFromBackup` if desired); delete the file in `removeVideo` and on import failure; pre-check `volumeAvailableCapacityForImportantUsage` against file size before copy and surface a friendly error. Sweep orphaned media on launch (files not referenced by the saved project).
- Blast radius: ImportView (VideoTransferable), DocumentPicker handler, ImportViewModel; pairs with C1.
- Verification: import then remove -> file gone; import with simulated low disk -> clear error.
- Confidence: high.

---

## MEDIUM

### M1. Auto-sync fires the instant imports finish — no review window, and double-trigger paths exist

- Refs: `Coreo/Import/ImportView.swift:68-76` (onChange pendingImports==0 -> sync), `:270-299` (manual Sync button also exists on error), `Coreo/Import/ImportViewModel.swift:53-55` (canSync only checks count+isSyncing)
- What's wrong (VERIFIED): The user cannot inspect/remove a mis-picked video before sync starts; every subsequent add re-triggers a full re-sync (all PCM extraction + correlation re-done); and if a file-picker Task dies mid-batch (view dismissed), `pendingImports` can stick > 0, silently disabling auto-sync with no indicator. There is also no debounce: picking 6 photos triggers sync exactly once (good) but add-tile then adds more during an in-flight sync are dropped by `canSync` and never re-run (user stuck until they notice the retry button only shows when `syncError != nil`).
- Recommended change: Replace auto-fire with an explicit prominent "Sync & Go" button once >= 2 videos (DESIGN.md actually specifies a Sync button + auto-transition on success); or keep auto-sync but debounce 1.5s after the last import, guard with a batch generation token, and reset `pendingImports` defensively in an `onDisappear`/error path.
- Blast radius: ImportView, ImportViewModel.
- Verification: UI test: pick videos, remove one within debounce, sync uses the reduced set.
- Confidence: high.

### M2. load() swallows all corruption silently; sanitizeIndices misses negative indices; offset reset destroys sync

- Refs: `Coreo/Models/CoreoProject.swift:172-185` (catch -> nil), `:91-103` (`min(referenceVideoIndex, count-1)` — no `max(0,...)`; count-mismatch resets ALL offsets to 0), `Coreo/Workspace/WorkspaceViewModel.swift:571-574` (`validReferenceIndex` also lacks negative guard -> `players[-1]` crash on tampered/corrupt JSON)
- What's wrong (VERIFIED, latent until C1 wires persistence): (1) Decode failure = silent fresh state, user's work gone with no message and no preserved file. (2) A negative `referenceVideoIndex`/`audioSourceIndex` from a corrupt file passes sanitize and crashes at `players[refIndex]`. (3) `sanitizeIndices` "repairs" an offsets-count mismatch by zeroing every offset — turning a recoverable mismatch into silently destroyed sync; removal flows should drop the corresponding offset instead.
- Recommended change: `sanitizeIndices`: clamp with `max(0, min(...))`; validate offsets are finite, replacing non-finite with 0. `load()`: on decode failure, rename the corrupt file to `coreo_project.corrupt.json` and return nil so the data is preserved for recovery, and surface "Couldn't read your last project" once persistence is user-visible. Add `schemaVersion` + custom `init(from:)` with `decodeIfPresent` defaults for forward compatibility.
- Blast radius: CoreoProject; WorkspaceViewModel guard.
- Verification: unit tests — negative indices, NaN offsets, truncated JSON, missing new fields.
- Confidence: high.

### M3. Export audio insertion uses the video-duration range on the audio track — throws if audio is shorter

- Refs: `Coreo/Export/ExportEngine.swift:206-217` (`compAudioTrack.insertTimeRange(sourceTimeRange, ...)` with `sourceTimeRange` built from the VIDEO duration at `:181-186`)
- What's wrong (INFERRED, API-contract): Audio tracks are routinely a few hundred ms shorter than the video track (encoder priming/trailing). `insertTimeRange` with a range exceeding the source track's timeRange throws (error -11823 family), failing the whole export with an opaque message. Same hazard exists for the video insert if stored `durationSeconds` (rounded through timescale 600 at import) exceeds the track's true duration by a frame.
- Recommended change: Clamp insertion ranges per-track: `let trackRange = try await sourceTrack.load(.timeRange); let safe = CMTimeRangeGetIntersection(sourceTimeRange, trackRange)` and insert `safe`. Apply for both audio and video inserts.
- Blast radius: ExportEngine.buildComposition.
- Verification: export a clip whose audio is shorter than video (ffmpeg-trimmed fixture) — export succeeds.
- Confidence: medium-high.

### M4. applySpeedSegments: unclamped ranges can raise ObjC exceptions (uncatchable crash)

- Refs: `Coreo/Export/ExportEngine.swift:225-260` (no clamping of `segStart`/durations against `composition.duration`; `insertEmptyTimeRange`/`scaleTimeRange` raise NSException on invalid ranges)
- What's wrong (INFERRED): Speed segments are created against the live timeline; nothing re-validates them at export time (e.g. segments beyond composition end after rounding, segments created then videos changed, overlapping segments if `project.speedSegments` was ever populated outside SpeedMap). AVFoundation's mutable-composition methods throw Objective-C exceptions for out-of-range operations, which Swift cannot catch -> hard crash mid-export.
- Recommended change: Before applying, clamp each segment to `[0, composition.duration]`, drop zero/negative-duration results, and assert-no-overlap (sort + merge). Do this in a small pure `func sanitizedSegments(_:, compositionDuration:) -> [SpeedSegment]` with unit tests.
- Blast radius: ExportEngine.
- Verification: unit test the sanitizer (incl. segment straddling composition end); manual export with a segment at the extreme end.
- Confidence: medium.

### M5. Backgrounding during export: GPU CIContext compositor will fail; expiration handler abandons silently

- Refs: `Coreo/Export/PanelCompositor.swift:71` (GPU CIContext), `Coreo/Export/ExportEngine.swift:428-440` (background task; expiration handler only ends the task — doesn't cancel the session or record state), EDGE-CASES.md:71 ("survives ~30 seconds")
- What's wrong (INFERRED, well-documented iOS behavior): Metal/GPU work is disallowed while backgrounded; a custom compositor rendering via GPU CIContext typically makes the export session fail (or stall) shortly after backgrounding, well before the ~30s background allowance ends. When the allowance does expire, the handler just ends the task: the suspended export dies and on foreground the user sees either a spurious failure alert or a stuck progress ring.
- Recommended change: Short-term: on `didEnterBackground` during export, surface a local notification or at minimum set a flag to present "Export was interrupted — keep Coreo in the foreground while exporting" on the failure path; create the CIContext with a CPU fallback (`.useSoftwareRenderer` respected only under background — or accept failure but message it). Proper fix: detect background transition and pause/cancel+restart export on foreground.
- Blast radius: ExportEngine, WorkspaceViewModel error messaging.
- Verification: device test — background at 50% export; observe outcome and message quality.
- Confidence: medium (mechanism certain, exact failure mode needs device confirmation).

### M6. EndBumperGenerator readiness loop can spin forever if the writer fails

- Refs: `Coreo/Export/EndBumperGenerator.swift:90-114` (`while !writerInput.isReadyForMoreMediaData { try await Task.sleep(10ms) }` — `writer.status` never checked inside the loop)
- What's wrong (VERIFIED structurally): If the AVAssetWriter transitions to `.failed` (disk full mid-bumper, session conflict), `isReadyForMoreMediaData` can stay false forever; the loop has no exit condition besides readiness, so `appendEndBumper` never returns and the export hangs at ~30% with no timeout (and cancel doesn't help — no cancellation check either).
- Recommended change: Inside the loop: `if writer.status == .failed { throw BumperError.writingFailed(...) }` and `try Task.checkCancellation()`; add a bounded total wait (e.g. 5s) as a belt-and-braces timeout (bumper failure is already non-fatal upstream at `ExportEngine.swift:94-103`).
- Blast radius: EndBumperGenerator.
- Verification: unit-test the loop guard via writer stub if practical; otherwise code-review-level assurance.
- Confidence: high.

### M7. FFT packed-format bin-0 corruption + full-energy confidence normalization

- Refs: `Coreo/Utilities/FFTHelper.swift:104-113` (complex multiply treats packed bin 0 — realp[0]=DC, imagp[0]=Nyquist — as an ordinary complex bin), `:192-204` (confidence = peak / sqrt(E_signal_total * E_reference_total))
- What's wrong (INFERRED, math): (1) vDSP_fft_zrip output packs DC into realp[0] and Nyquist into imagp[0]; multiplying bin 0 as a normal complex pair cross-contaminates DC and Nyquist, adding a small error to every correlation value. Usually negligible for music, but it biases low-frequency-heavy or near-silent signals exactly where confidence is marginal. (2) Confidence divides by total energies of both FULL signals: two clips that overlap for only 30s of a 5-minute recording get a confidence penalized by all the non-overlapping energy — perfectly-syncable pairs land under the 0.3 threshold and get flagged unreliable (false alarms documented as a UX flow, see H9). This is also why EDGE-CASES.md's "Silent audio ... confidence 0" works, but partially-overlapping long takes misbehave.
- Recommended change: (1) Handle bin 0 specially: `productReal[0] = refReal[0]*sigReal[0]; productImag[0] = refImag[0]*sigImag[0]` (DC*DC and Nyquist*Nyquist are both real). (2) Normalize by the energy of the OVERLAPPING windows at the found lag (compute overlap energies with `vDSP_dotpr` over the aligned subranges), or normalize per-sample (peak / overlapLength / rms1 / rms2). Re-tune the 0.3 threshold afterward against the existing AudioSyncTests + new partial-overlap fixtures.
- Blast radius: FFTHelper (+ threshold), AudioSyncTests.
- Verification: extend AudioSyncTests: partial-overlap case (30s common audio inside 3-min signals) must clear the threshold; DC-offset signal case.
- Confidence: medium-high (bin-0: high; threshold retune needs experiments).

### M8. VNDetectHumanRectanglesRequest defaults to upper-body only — dancers' legs get cropped

- Refs: `Coreo/Crop/PersonDetector.swift:130-141` (request created with defaults)
- What's wrong (INFERRED, API default): On iOS 15+, `VNDetectHumanRectanglesRequest` (revision 2) defaults to `upperBodyOnly = true`. The "activity region" union therefore covers torsos/heads; the 15% padding often will not reach feet — for a choreography app, footwork is exactly what gets cropped out (and H6 will make this visible in exports once fixed).
- Recommended change: Set `request.upperBodyOnly = false`. Verify on-device with full-body test footage; consider increasing bottom padding asymmetrically as a safety margin.
- Blast radius: PersonDetector one line.
- Verification: device run on full-body dance clip; crop rect includes feet.
- Confidence: medium-high (API default verified against memory of Vision docs — implementer should confirm with current docs).

### M9. No AVPlayerItem failure observation — missing/corrupt media yields silent black panels

- Refs: `Coreo/Workspace/WorkspaceViewModel.swift:399-422` (setupPlayers — no `.status`/`AVPlayerItem.failedToPlayToEndTimeNotification` observation), DESIGN.md:405 ("warning if the source video is deleted/moved"), EDGE-CASES.md:103 ("Validate video file existence on project load" — deferred)
- What's wrong (VERIFIED absence): If a tmp-stored video was purged (H11) or the item fails to decode, the panel just renders black with no message; the timeline still counts the video. Export later fails with a raw AVFoundation error from `loadAssets` (`ExportEngine.swift:142-150` — message like "The requested URL was not found on this server" leaks through).
- Recommended change: Observe each item's `status` via KVO/publisher; on `.failed`, overlay "Video unavailable" on the panel and exclude it from export (or block export with a clear message naming the file). On workspace entry, pre-flight `FileManager.fileExists` for each `localURL`.
- Blast radius: WorkspaceViewModel, VideoPanelView (overlay reuse), ExportEngine pre-flight.
- Verification: delete a tmp file behind a live project; panel shows error state; export message names the file.
- Confidence: high.

### M10. Annotation time-range control is dead code — ranges and "Show always" are unreachable

- Refs: `Coreo/Annotations/AnnotationTimeRangeControl.swift` (complete, never instantiated — zero references outside its own file), DESIGN.md:234-247
- What's wrong (VERIFIED): Annotations are stuck with the 3s default window; the DESIGN-specified range handles and persistent toggle have a fully built control that is wired to nothing. Users cannot extend, shorten, or persist annotations; `isPersistent` can never be true, so the persistent code paths (e.g. `AnnotationCompositor.swift:344-349`) are untested dead branches.
- Recommended change: Present `AnnotationTimeRangeControl` when `selectedAnnotationID != nil` (below the timeline or as a popover), bound to the selected annotation's fields via a Binding into `project.annotations`.
- Blast radius: WorkspaceView/AnnotationOverlayView wiring; no model change.
- Verification: select annotation -> control appears; drag handles -> visibility window changes during playback.
- Confidence: high.

### M11. Trim is a UI ghost: fields render an overlay but nothing sets them and export ignores them

- Refs: `Coreo/Models/CoreoProject.swift:49-52`, `Coreo/Workspace/TimelineView.swift:263-304` (renders if set), zero writers anywhere; EDGE-CASES.md:70 (deferred), DESIGN.md "Trim to overlap" button
- What's wrong (VERIFIED): `timelineTrimStartSeconds/DurationSeconds` have no setter UI (the DESIGN "Trim to overlap" one-tap button is unimplemented — note `overlapStartSeconds`/`overlapEndSeconds` already exist on the model at `CoreoProject.swift:130-144`) and ExportEngine never consumes them. If they ever become non-nil (future persistence + version skew), export output won't match the dimmed preview.
- Recommended change: Either implement minimally — a "Trim to overlap" toolbar button setting the fields from `overlapStartSeconds/overlapEndSeconds`, plus export support (offset all insertions by -trimStart and cap composition duration; or apply `exportSession.timeRange`) — or remove the fields + overlay until scheduled. `exportSession.timeRange = CMTimeRange(start: trimStart - timelineStart, duration: trimDuration)` is the cheap correct path (applies after speed scaling — document the interaction or apply before speed mapping).
- Blast radius: ExportEngine (timeRange), WorkspaceView button, TimelineView already done.
- Verification: trim to overlap; exported duration == overlap window (account for speed segments).
- Confidence: high (gap), medium (speed-segment interaction needs care).

### M12. Export disk-space check is a fixed 500 MB regardless of content; no size estimate

- Refs: `Coreo/Export/ExportEngine.swift:64,486-492`
- What's wrong (VERIFIED): A 10-minute 6-angle 1080p export at high quality can exceed 500 MB output (plus AVFoundation scratch). The check also silently passes if attributes can't be read, and uses `attributesOfFileSystem` rather than the more accurate `volumeAvailableCapacityForImportantUsage`.
- Recommended change: Estimate `bytes ~= duration * bitrate(resolution)` (e.g. 10 Mbps at 1080p30 -> ~75 MB/min) with a 2x margin; query `temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`; fail with the existing `.diskFull` error.
- Blast radius: ExportEngine.checkDiskSpace.
- Verification: unit test the estimator; manual low-disk simulator test.
- Confidence: high.

### M13. No memory-warning / thermal / low-power adaptation anywhere

- Refs: zero hits for `didReceiveMemoryWarning`/`thermalState`/`isLowPowerModeEnabled` across `Coreo/`; EDGE-CASES.md:102 (memory-warning handler deferred)
- What's wrong (VERIFIED absence): Six AVPlayers + thumbnails + (post-C5) sync buffers, with no response to memory pressure — jetsam instead of degradation. No pause of non-essential work (person detection, bumper prerender) under `.serious` thermal state.
- Recommended change: Observe `UIApplication.didReceiveMemoryWarningNotification` in WorkspaceViewModel: drop `thumbnailData` copies, set `preferredForwardBufferDuration = 1` on non-audible players, and (optional) pause players for panels that are currently inactive. Thermal/low-power: defer; document as accepted risk if not implemented (For JMT).
- Blast radius: WorkspaceViewModel.
- Verification: simulator Simulate Memory Warning during 6-video playback; no crash, buffers shrink.
- Confidence: medium (benefit), high (absence).

### M14. Unreliable-video removal leaves referenceVideoIndex/offsets denormalized

- Refs: `Coreo/Import/ImportViewModel.swift:156-187` (`referenceVideoIndex: 0` hardcoded; kept offsets are still relative to the REMOVED-set reference; offsets not re-zeroed to the new reference)
- What's wrong (VERIFIED): After "Remove" in the unreliable alert, the rebuilt project sets `referenceVideoIndex = 0` but keeps offsets relative to the original reference video (which survives — it can't be unreliable — but may not sit at index 0). The invariant documented at `CoreoProject.swift:33` ("syncOffsets[referenceVideoIndex] should always be 0") breaks. Current playback math tolerates it (everything is offset-relative), but timelineStart shifts and any future code trusting the invariant (e.g. nudge UI, persistence migration) inherits a lie.
- Recommended change: After filtering, find the surviving original reference's new index `r`; set `referenceVideoIndex = r` and renormalize `offsets = offsets.map { $0 - offsets[r] }` (no-op if reference offset already 0). One unit test locks the invariant.
- Blast radius: ImportViewModel.finalizeProject.
- Verification: unit test with reference at index 1 and an unreliable video at index 0 removed.
- Confidence: high.

### M15. ExportEngine surfaces raw AVFoundation errors; several failure paths lack user-meaningful messages

- Refs: `Coreo/Export/ExportEngine.swift:142-150` (loadAssets throws raw), `:476` (session error string passthrough), `Coreo/Import/ImportViewModel.swift:72` ("Failed to import X: The operation could not be completed" class of messages)
- What's wrong (VERIFIED): Missing file, codec failure, and session errors reach the alert as low-level localizedDescriptions. The error table in EDGE-CASES.md:76-91 implies curated messages; several paths bypass it.
- Recommended change: Wrap loadAssets failures: catch and rethrow `ExportError.compositionFailed("Couldn't open \(video.localURL.lastPathComponent). The file may have been moved or deleted.")`. Map common AVError codes (notably `.fileFormatNotRecognized`, `.noLongerPlayable`, `.diskFull`) to friendly strings in one helper used by both import and export.
- Blast radius: ExportEngine, ImportViewModel, small error-mapping utility.
- Verification: manual: delete backing file, export; message names the file and suggests action.
- Confidence: high.

---

## LOW

### L1. PanelCompositor orientation mapping ignores mirrored/scaled transforms

- Refs: `Coreo/Export/PanelCompositor.swift:193-210`
- What's wrong (VERIFIED): Only the 4 standard rotations are handled; mirrored front-camera transforms (negative determinant) and any scale/translation-bearing transform fall through to `.up`, exporting flipped/wrong orientation. Front-camera "selfie" recordings of dance practice are plausible inputs.
- Recommended change: Extend mapping to the 8 CGImagePropertyOrientation cases by inspecting (a,b,c,d) signs including mirror cases (`.upMirrored`, `.leftMirrored`, etc.).
- Verification: fixture video with mirrored transform; export orientation matches preview.
- Confidence: medium.

### L2. Exported temp files leak when the app dies before share-sheet dismissal

- Refs: `Coreo/Export/ExportEngine.swift:423-424` (UUID names in tmp), `Coreo/Workspace/WorkspaceViewModel.swift:352-357` (cleanup only on sheet dismiss)
- What's wrong (VERIFIED): Kill/crash between export completion and share dismissal orphans `coreo_export_*.mp4` (full-size). Plus H3's cancelled-session orphans and bumper files on the appendEndBumper failure path before `removeItem`.
- Recommended change: On app launch, sweep `tmp` for `coreo_export_*` / `coreo_bumper_*` older than 1 hour.
- Verification: create stale files, launch, files removed.
- Confidence: high.

### L3. `print` instead of os.Logger; audio-session failure swallowed

- Refs: `Coreo/App/CoreoApp.swift:31`, `Coreo/Export/ExportEngine.swift:102`
- Recommended change: `os.Logger` subsystem `com.coreo.app`; categories "export"/"audio". Audio-session failure is benign-ish (playback still works with default category) — log only. (VERIFIED)
- Confidence: high.

### L4. Audio session activated at launch and never deactivated/reconfigured

- Refs: `Coreo/App/CoreoApp.swift:26-33`; PERFORMANCE.md Medium-Deferred acknowledges
- What's wrong (VERIFIED): `.playback` + `setActive(true)` at init kills any background music the moment Coreo launches, even on the import screen where no audio plays. Polite apps activate on first playback.
- Recommended change: Move `setActive(true)` to WorkspaceViewModel.init / first play; deactivate with `.notifyOthersOnDeactivation` in tearDown.
- Confidence: high.

### L5. Negative-time display clamps to 0:00

- Refs: `Coreo/Utilities/TimeFormatting.swift:17,39` (`max(0, seconds)`), timeline start can be negative (`CoreoProject.swift:108-111`)
- What's wrong (VERIFIED): With a negative min offset, the playhead label reads 0:00 for the first portion and total-duration label understates. Cosmetic; consider rebasing display to `t - timelineStart`.
- Confidence: high.

### L6. ModelTests mutate the real Documents save file (test pollution)

- Refs: `CoreoTests/UnitTests/ModelTests.swift:249-276`, `CoreoProject.swift:149-158` (hardcoded path, untestable injection point)
- What's wrong (VERIFIED): save/load tests share one global file; order-dependent results and leftover state on the simulator. Recommended: parameterize the storage URL (default Documents), point tests at a temp dir; this also unblocks C1's autosave tests.
- Confidence: high.

### L7. AnnotationCompositor latent bugs for when annotation export is re-enabled

- Refs: `Coreo/Export/AnnotationCompositor.swift:326-402` (keyTimes can go non-monotonic when `durationSeconds < 0.4` since fadeOutStart < fadeInEnd; no clamp for relativeStart < 0), `:172` (scaleFactor hardcodes 375pt authoring width — annotations are authored against the video-GRID container, whose aspect differs from export renderSize, so positions will drift when integrated), annotations also ignore speed-segment time remapping (a note placed at t=10s shows at composition-time 10s even though speed changes moved that content)
- What's wrong (VERIFIED latent — code path currently disabled at `ExportEngine.swift:120-125`): Three traps waiting for the "integrate annotations into PanelCompositor" deferred task. Flagging now so the implementing agent designs for: monotonic keyTime clamping, container-to-render coordinate mapping (store grid aspect or normalize against grid rect), and timeline->composition time remapping through the speed map.
- Confidence: high (as latent issues).

### L8. Hex color parsers silently produce black/wrong colors on malformed input

- Refs: `Coreo/Annotations/AnnotationModel.swift:239-276`, `AnnotationCompositor.swift:17-27`, `AnnotationOverlayView.swift:379-389` (3 duplicate parsers, no validation)
- Recommended change: Consolidate into one util; return nil/fallback-accent on parse failure. (VERIFIED; cosmetic)
- Confidence: high.

### L9. VideoPanelView crop mask geometry is wrong-ish and recreated every update

- Refs: `Coreo/Workspace/VideoPanelView.swift:171-190` (mask rect = crop applied to VIEW bounds, but video is aspect-FILLED — mask region doesn't correspond to the crop in video coordinates; result is cropping the visible viewport, not the frame; also masks to a sub-rect of the panel leaving dead margins instead of scaling crop to fill panel), PERFORMANCE.md High-Deferred notes the allocation churn
- What's wrong (VERIFIED geometry reasoning, needs visual confirm): The live "crop" both shows the wrong region (ignores aspect-fill overflow mapping) and shrinks visible content into a sub-rect rather than filling the panel with the cropped region (which is what export-side H6's fix will do — another preview/export divergence axis). Suggest reimplementing live crop via `AVPlayerLayer` inside a container view where the layer is scaled/offset so the crop region fills the panel (transform math identical to PanelCompositor's, keeping the two paths in lockstep).
- Confidence: medium (needs device visual check) — coordinate with whoever fixes H6 to share the mapping function.

---

## For JMT (needs a real device / product judgment)

- Hold behavior end-to-end (C3/H4): confirm on device, then decide whether holds freeze with audio silence (current export model) or audio continues (would need different composition strategy).
- Background-export policy (M5): is "keep Coreo foregrounded while exporting" an acceptable v1 stance? If yes, a one-line notice in the progress card makes M5 cheap.
- HDR/Dolby Vision clips alongside SDR: EDGE-CASES says washed-out is accepted for v1 — worth one device look at iPhone 15+ default-camera HDR footage since that's now the COMMON case, not the edge.
- VFR slow-mo (240fps) imported via photo picker: claimed supported; worth one manual sync+export run.
- Thermal throttling during 6-angle playback + export on older devices: no in-app mitigation (M13) — accept or schedule.

---

## TOP 10 (priority order)

1. C1 Wire persistence: autosave on mutation/background, load on launch, schemaVersion field, files out of tmp (with H11).
2. C2 Stop one silent video from killing sync: filter to audio-bearing videos, per-video failure degradation (restores EDGE-CASES.md's claimed behavior).
3. C3 Fix live holds: interval-crossing trigger + scheduled resume; never strand playback paused with isPlaying=true.
4. H3 Make export cancel real: cancelExport() on the session, checkCancellation between steps, block double export, clean temp files.
5. C5 Cap sync memory: windowed correlation + max 2 concurrent correlations (jetsam fix for 10-min clips).
6. H4+H6 Export fidelity: holds render frozen frames not black; PanelCompositor honors cropRect (preview == export).
7. H1 Cap imports at 6 with a friendly error; layout fallback instead of blank grid.
8. H7+H10 Import error surfacing: no more try?-swallowed photo-picker failures; thumbnail failure degrades to placeholder instead of blocking import.
9. H8 Audio-session interruption handling (phone call/Siri/route change) mirroring the existing background path.
10. H5+H9 Timeline correctness + recovery: loop/clock keyed to latest-ending video; manual sync nudge UI + absurd-offset gate.

C4 (doc/code divergence sweep) should ride along with whichever PR touches Sync/ — update EDGE-CASES.md and PERFORMANCE.md to match reality in the same change.
