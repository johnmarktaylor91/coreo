# Coreo Improvement Survey — Architecture, Code Quality & Test Coverage

Survey date: 2026-06-11. Static analysis only (xcodebuild broken on this machine).
Codebase: 9,036 lines Swift across 47 files (37 app, 5 test files, ~74 tests).
Severity scale: Critical / High / Medium / Low. Each finding labels evidence as
VERIFIED (read directly in code) or INFERRED (reasoned consequence, not executed).

Implementor note: file:line references are against the working tree at survey time
(single commit `9346ce5`, all app sources untracked). Re-grep the anchor snippets if
lines have shifted.

---

## CRITICAL

### C1. Late-starting videos play permanently desynced during live playback

- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift:399-422` (`setupPlayers`),
  `:534-540` (`videoTime(forTimeline:videoIndex:)`), `:543-556` (`seekAll`/`playAll`)
- **What's wrong (VERIFIED logic, INFERRED runtime):** `videoTime` clamps per-video
  time to `max(0, timelineSeconds - syncOffsets[i])`. A video whose `syncOffset` is
  greater than `timelineStart` (i.e., any video that is not the earliest-starting
  one — the common case the sync engine exists for) is seeked to its frame 0 at
  timeline start, and `playAll()` starts ALL players immediately at the same rate.
  Nothing pauses inactive players or re-seeks them when their panel becomes active
  (`isVideoActive` only drives the dark overlay in `VideoGridView`). So by the time
  timeline t reaches the video's `offset`, that player is already
  `(offset - timelineStart)` seconds into its content and stays wrong forever.
  Example: offsets `[0, +3]` -> video B is revealed at t=3 already 3 s ahead.
- **Recommended change:** Introduce per-player activation: in `setupPlayers`/`seekAll`,
  pause players whose `videoSeconds < 0` and hold them seeked at 0; in the periodic
  time observer (`installTimeObserver`, :428-448), when a video transitions
  inactive->active, seek it to `timelineSeconds - offset` (tolerance .zero) and set
  `rate = effectiveRate`. Symmetrically pause players past their end. Cleanest shape:
  extract a pure `PlayerSyncPlan` (input: timelineSeconds, offsets, durations,
  isPlaying, rate; output: per-player `.playing(at: CMTime)/.pausedAt(.zero)/.ended`)
  so the policy is unit-testable, with the VM applying the plan.
- **Blast radius:** WorkspaceViewModel only; behavioral change for all multi-angle
  playback. Export path unaffected (composition inserts at correct offsets).
- **Verification/test:** Unit-test `PlayerSyncPlan` (pure). Manual: import 2 clips
  started ~3 s apart, confirm second panel begins at its first frame when revealed.
- **Confidence:** High (the code path is unambiguous; only runtime confirmation missing).

### C2. Annotations are invisible during normal playback and skipped in export — the feature only exists inside annotation mode

- **Files:** `Coreo/Workspace/WorkspaceView.swift:49-56` (overlay gated on
  `viewModel.isAnnotationMode`), `Coreo/Export/ExportEngine.swift:120-125` (Step 6
  comment: annotations skipped), `Coreo/Export/ExportEngine.swift:395-413`
  (`applyAnnotationOverlay` — never called; VERIFIED via grep: zero call sites)
- **What's wrong (VERIFIED):** DESIGN.md specifies time-stamped annotations that fade
  in/out during playback and appear in the exported .mp4. Reality: (a)
  `AnnotationOverlayView` (which already renders visible annotations with
  `opacity(at:)`) is only mounted when annotation mode is active, and entering
  annotation mode pauses playback (`enterAnnotationMode`, WorkspaceViewModel:195-201).
  So fade-in/out is never seen while playing. (b) Export deliberately skips
  annotations because `AVVideoCompositionCoreAnimationTool` is incompatible with the
  custom `PanelCompositor`; the entire 403-line `AnnotationCompositor.swift` is dead
  weight behind a never-called private function.
- **Recommended change:** (a) Playback: split the overlay into a read-only renderer
  (always mounted over `VideoGridView`, hit-testing disabled) and an interaction layer
  (mounted only in annotation mode). The current `ZStack` in `AnnotationOverlayView`
  already separates these (`visibleAnnotations` loop vs `toolLayer`); move the render
  loop out of the `if isAnnotationMode` gate in WorkspaceView. (b) Export: render
  annotations inside `PanelCompositor.compositeFrame` — convert each visible
  annotation at `compositionTime` to a CIImage (rasterize text/arrows once per
  annotation into a cache keyed by annotation id, modulate alpha via
  `opacity(at:)`-equivalent computed from the instruction time), and composite over
  the panel result. Reuse `TimedAnnotation.opacity(at:)` so playback and export share
  fade math. Delete `AnnotationCompositor` or repurpose its rasterization helpers.
- **Blast radius:** WorkspaceView, AnnotationOverlayView, PanelCompositor,
  ExportEngine, AnnotationCompositor. The user-visible feature contract of the app.
- **Verification/test:** Unit-test the annotation->CIImage frame-visibility math
  (pure: time -> alpha); manual export with a text annotation and confirm presence at
  the right timestamps.
- **Confidence:** High.

### C3. Hold ("freeze frame") is broken in both live playback and export

- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift:513-529`
  (`applyLiveSpeedSegment`), `Coreo/Export/ExportEngine.swift:237-244`
  (`applySpeedSegments` hold branch), `Coreo/Speed/SpeedControlView.swift:388-402`
  (`addHoldSegment` — 0.01 s footprint, `holdDurationSeconds` stored separately)
- **What's wrong:**
  - Live (VERIFIED logic): when the playhead enters a hold segment, all players are
    paused while `isPlaying` stays true. The periodic time observer only fires while
    time advances, so `applyLiveSpeedSegment` is never re-invoked, `currentTimeSeconds`
    freezes, and playback never resumes — a hold is an infinite freeze until the user
    toggles pause/play. `holdDurationSeconds` is never consulted in live playback.
  - Export (VERIFIED): `composition.insertEmptyTimeRange` inserts a media GAP, not a
    frozen frame. With `PanelCompositor`, `request.sourceFrame(byTrackID:)` returns
    nil during the gap -> `continue` -> the panel renders as background color. The
    exported "freeze" is a black/empty hold, in every panel.
- **Recommended change:** Live: on entering a hold, schedule resume explicitly —
  record `holdUntil = CACurrentMediaTime() + holdDurationSeconds` and use a Task
  sleep (or `AVPlayer.addBoundaryTimeObserver` alternative) to call
  `seekAll(to: segment.endTimeSeconds); playAll()` when it elapses; cancel on
  scrub/pause. Export: replace `insertEmptyTimeRange` with
  `scaleTimeRange(CMTimeRange(start: segStart, duration: oneFrame), toDuration: holdDuration)`
  on every video track (freeze by stretching a single frame), which works unchanged
  with PanelCompositor.
- **Blast radius:** WorkspaceViewModel, ExportEngine; SpeedMap semantics unchanged.
- **Verification/test:** Unit-test an extracted `SpeedTimelineMapper` (timeline time ->
  composition time under segments+holds) — currently zero tests exist for any speed
  logic (see T-plan). Manual: export with one hold; confirm frozen image not black.
- **Confidence:** High for export gap; High for live stall (API contract of
  `addPeriodicTimeObserver` is "fires during playback").

### C4. PERFORMANCE.md / EDGE-CASES.md claim fixes that are absent from the code (doc-code drift will mislead implementing agents)

- **Files/claims (all VERIFIED absent by grep):**
  - PERFORMANCE.md "High #4: autoreleasepool in AudioExtractor read loop" — no
    `autoreleasepool` anywhere in `Coreo/Sync/AudioExtractor.swift` (loop at :92-99).
  - PERFORMANCE.md "High #6: reserveCapacity on audio samples array" — no
    `reserveCapacity` in AudioExtractor (`var allSamples: [Float] = []` at :90).
    EDGE-CASES.md likewise references a reserveCapacity guard that does not exist.
  - PERFORMANCE.md "High #5: double copy fixed, single copy" — `extractFloats`
    (:126-156) still copies CMBlockBuffer -> `Data` -> `Array` (two copies).
  - PERFORMANCE.md "High #7: scalar FFT multiply replaced with vDSP_zvmul" —
    `FFTHelper.swift:110-113` is still a scalar `for` loop.
  - PERFORMANCE.md "Medium #6: Task.checkCancellation added to AudioSyncEngine" —
    not present in `AudioSyncEngine.swift` (PersonDetector has it; sync does not).
  - EDGE-CASES.md "No-audio videos: filter to audio-bearing videos for sync, flag
    no-audio as unreliable (ImportViewModel)" — `ImportViewModel.sync()` (:96-140)
    passes ALL videos unfiltered; see H5.
- **What's wrong:** Either the fixes were lost (reverted/never landed) or the docs
  were written aspirationally. Since a Codex fleet will implement from these reports
  and from repo docs, stale "fixed" claims are actively dangerous.
- **Recommended change:** Re-apply the six missing fixes (each is small and
  well-specified by its own doc entry), then correct both docs to match reality.
  Treat docs' "Deferred" tables as the only trustworthy backlog until re-audited.
- **Blast radius:** AudioExtractor, FFTHelper, AudioSyncEngine, ImportViewModel, docs.
- **Verification/test:** grep-based assertions in review; AudioExtractor perf fixes
  are behavior-neutral (existing AudioSyncTests must stay green).
- **Confidence:** High.

---

## HIGH

### H1. Persistence is dead code: `save()`/`load()` never called; no schema versioning; model shape contradicts DESIGN

- **Files:** `Coreo/Models/CoreoProject.swift:146-186`; call-site grep: `save()` /
  `CoreoProject.load()` appear ONLY in `CoreoTests/UnitTests/ModelTests.swift`
  (VERIFIED). DESIGN.md says "Projects are self-contained directories."
- **What's wrong:** (a) The app loses everything on relaunch — no code path persists
  or restores a project. (b) Persistence as written is a single hardcoded
  `Documents/coreo_project.json` (one project max). (c) No `schemaVersion` field —
  any future model change silently breaks decoding, and `load()` swallows decode
  errors by returning nil (silent data loss). (d) `VideoAsset.localURL` stores an
  absolute URL; both import paths copy media into `FileManager.temporaryDirectory`
  (`ImportView.swift:361-377` VideoTransferable; DocumentPicker `asCopy: true`), so
  a persisted project would reference purged tmp files AND the app-container UUID in
  absolute paths changes across app updates. Persisting this model as-is can never
  work.
- **Recommended change (FULL-OVERRIDE data-model reshape — see H3 for the shape):**
  1. Project store: `Documents/Projects/<uuid>/project.json` + `media/` subdirectory;
     imports COPY (not reference) into `media/`; `VideoAsset` stores a
     project-relative path (`var relativePath: String`), with a computed
     `localURL(in projectRoot:)`.
  2. Add `let schemaVersion: Int` (current = 1 since nothing has shipped;
     `decodeIfPresent ?? 1`). Decode via a `ProjectFileEnvelope { schemaVersion; payload }`
     or a top-level field checked before full decode.
  3. Wire it: save on workspace changes (debounced) and on `scenePhase == .background`;
     load/restore on launch (ContentView).
  4. `load()` must distinguish "no file" from "corrupt file" (log + surface, keep a
     `.bak` of the last good save).
- **Migration path:** None needed for users (persistence never shipped, repo has a
  single initial commit). For the dev device only: treat absence of `schemaVersion`
  as v0 and discard (current behavior already discards everything). Lock the format
  with a checked-in v1 fixture JSON decoded in tests so future schema changes require
  an explicit migration function.
- **Blast radius:** Models, Import, ContentView, WorkspaceViewModel, tests.
- **Verification/test:** Round-trip + fixture-decode tests; relaunch-restore manual test.
- **Confidence:** High.

### H2. Smart-crop is ineffective: export ignores `cropRect` entirely; preview "crop" is a mask, not a crop

- **Files:** `Coreo/Export/PanelCompositor.swift:34` (`PanelConfig.cropRect` declared;
  VERIFIED by grep it is never read in `compositeFrame`), `Coreo/Workspace/VideoPanelView.swift:160-190`
  (`applyCropMask` masks the VIEW with the normalized rect instead of zooming the
  cropped region to fill the panel).
- **What's wrong:** The Vision/SmartCropEngine pipeline computes normalized crop
  rects and `ImportViewModel` stores them, but: export composites the full frame
  (dead `cropRect` parameter); preview applies a CAShapeLayer mask in view space over
  an aspect-FILL layer, which (a) is geometrically wrong (crop is normalized to the
  video frame, the mask is applied in panel space) and (b) blacks out panel area
  rather than enlarging the person region. Net effect: the entire Crop/ module
  (318 lines + sync cost at import) produces nearly no user-visible value.
- **Recommended change:** Export: in `compositeFrame`, after orienting the source
  image, apply `image = image.cropped(to: cropRect mapped into image extent)` BEFORE
  the aspect-fill scale (and translate so the cropped origin is at zero). Preview:
  replace the mask with the same math — compute scale/offset so the crop region
  aspect-fills the panel (set `playerLayer` contentsRect is not available; instead
  apply transform on the player layer, or wrap in a scroll/zoom container reusing the
  existing zoom transform plumbing in `VideoPanelView`). Factor the
  crop-to-panel mapping into one pure function shared by both (see M6).
- **Blast radius:** PanelCompositor, VideoPanelView; no model change.
- **Verification/test:** Pure geometry unit tests (crop rect + panel rect + video size
  -> transform); manual visual check.
- **Confidence:** High (dead parameter is certain; preview-mask critique is VERIFIED
  geometry reading).

### H3. Data model: index-coupled parallel arrays (`syncOffsets`, `cropOverrides[Int]`, `layoutOverrides.panelRects`, `referenceVideoIndex`, `audioSourceIndex`)

- **Files:** `Coreo/Models/CoreoProject.swift:27-55`
- **What's wrong (VERIFIED):** Five pieces of state are correlated with `videos` by
  array position. Any add/remove/reorder must update all of them in lock-step;
  `sanitizeIndices()` (:91-103) papers over count mismatches by ZEROING all offsets
  (destroying sync data) and is only called from ExportEngine, not after
  `ImportViewModel.removeVideo`. `finalizeProject(includeUnreliable: false)`
  (ImportViewModel:148-188) already exhibits the bug class: it filters videos but
  hardcodes `referenceVideoIndex: 0`, so the recorded reference no longer matches the
  video whose offset is 0.
- **Recommended change (in scope per brief):** Move per-video state onto the video:
  ```swift
  struct VideoAsset: Codable, Identifiable {
      let id: UUID
      var relativePath: String          // see H1
      let durationSeconds: Double
      let dimensions: CGSize
      let audioBitrate: Int
      let audioSampleRate: Int
      var thumbnailData: Data?
      var syncOffsetSeconds: TimeInterval = 0   // NEW
      var cropRect: CGRect?                      // NEW (normalized, top-left origin)
      var panelRectOverride: CGRect?             // NEW (normalized)
  }
  struct CoreoProject {
      ...
      var referenceVideoID: UUID?       // replaces referenceVideoIndex
      var audioSourceID: UUID?          // replaces audioSourceIndex
  }
  ```
  Keep computed helpers (`timelineStartSeconds` etc.) — they become simple maps over
  `videos`. Delete `LayoutOverrides`, `cropOverrides`, `syncOffsets`,
  `sanitizeIndices` (ID lookups can't go stale; nil-coalesce missing IDs to first
  video). Consumers to update: WorkspaceViewModel (`syncOffsets[index]` x6),
  ExportEngine, VideoGridView, TimelineView, ImportViewModel.
- **Migration path:** Nothing shipped (see H1) -> reshape now, bump `schemaVersion`
  to 1 with this shape as the baseline, check in a v1 fixture test. If JMT wants
  belt-and-braces, add a one-shot decoder that accepts the old parallel-array JSON
  (decode old struct, zip arrays onto videos by index) — ~30 lines, only needed for
  dev-device continuity.
- **Blast radius:** Models + every module that indexes by position (mechanical but
  wide; good single Codex wave with full test run).
- **Verification/test:** ModelTests rewritten for new shape; a regression test that
  removing video 0 preserves the other videos' offsets/crops (fails today by design).
- **Confidence:** High that this is an improvement; the migration risk is nil today
  and grows with every week persistence stays unwired.

### H4. WorkspaceViewModel is a God object and the whole workspace re-renders at 30 Hz

- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift` (606 lines, 17 `@Published`
  properties — VERIFIED count; playback + annotation CRUD + annotation tool UI state
  + speed UI state + export orchestration + export UI state + lifecycle observers).
  All seven workspace views take `@ObservedObject var viewModel: WorkspaceViewModel`.
- **What's wrong:** `currentTimeSeconds` is `@Published` and updated ~30 Hz by the
  time observer; with `ObservableObject`, every observing view's body re-evaluates on
  every tick — TimelineView, VideoGridView (recomputes `panelRects` via LayoutEngine
  each tick), SpeedControlView, PlaybackControlsView, AnnotationOverlayView (which
  also re-rasterizes PKDrawings — see M7). Beyond performance, the type violates the
  400-line guideline and mixes at least four responsibilities; properties are
  scattered (`@Published` declared at :186-192, :297, :302 mid-file between methods).
- **Recommended change:** Split along existing MARK seams, keeping `WorkspaceViewModel`
  as a thin composer:
  - `PlaybackController` (players, time observer, seek/rate/loop/lifecycle, C1/C3 fixes)
  - `AnnotationStore` (annotations CRUD + selection/tool state)
  - `ExportCoordinator` (startExport/cancel/cleanup/progress/share-sheet state)
  - UI toggles stay in the VM.
  Deployment target is iOS 16, so `@Observable` (iOS 17) is unavailable — either bump
  the target (JMT decision; see "For JMT") or rely on the split so high-frequency
  state (`currentTimeSeconds`) lives in a small `PlaybackController` observed only by
  TimelineView/PlaybackControls, while VideoGridView observes only layout-relevant
  state. Pass plain values (current time) into leaf views where possible.
- **Blast radius:** Workspace module; all workspace views change initializer wiring.
- **Verification/test:** Behavior-preserving refactor gated on the new unit tests in
  the test plan (playback math, annotation CRUD) written FIRST against the current VM.
- **Confidence:** High.

### H5. One audio-less (or silent-extract) video makes the entire sync throw, contradicting the documented design

- **Files:** `Coreo/Sync/AudioSyncEngine.swift:108-141` (TaskGroup rethrows
  `audioExtractionFailed`), `Coreo/Import/ImportViewModel.swift:104-106` (no
  filtering), `Coreo/Models/VideoAsset.swift:109-119` (audio optional, bitrate 0)
- **What's wrong (VERIFIED):** VideoAsset deliberately allows audio-less imports
  (bitrate 0), EDGE-CASES.md says such videos are filtered and flagged unreliable,
  but `sync()` passes them straight through; `AudioExtractor.extractPCM` throws
  `.noAudioTrack`, the task group rethrows, and the user gets a hard "Sync failed"
  for the whole batch. Also `chooseReference` could pick a bitrate-0 video when all
  are 0.
- **Recommended change:** In `AudioSyncEngine.sync` (better than ImportViewModel, so
  the engine's contract is self-consistent): partition inputs into audio-bearing
  (bitrate > 0) and silent; require >= 2 audio-bearing else throw
  `insufficientVideos`; run correlation on audio-bearing only; emit `SyncResult`
  with `confidence: 0, isReliable: false, offsetSeconds: 0` for silent ones so the
  existing unreliable-confirmation UI handles them.
- **Blast radius:** AudioSyncEngine; ImportViewModel unchanged.
- **Verification/test:** Engine-level test with injected extractor (see H6) where one
  input throws `.noAudioTrack` -> expect flagged-unreliable, not thrown.
- **Confidence:** High.

### H6. No protocol seams: engines are static enums with hard-wired dependencies — orchestration logic is untestable without real media

- **Files:** `AudioSyncEngine.swift:101,116` (calls `AudioExtractor.extractPCM`
  statically), `SmartCropEngine.swift:93` (calls `PersonDetector.detectPersons`
  statically), `ExportEngine.swift` (static; constructs `AVAssetExportSession`,
  `EndBumperGenerator` inline), `ImportViewModel.swift:106,210` (calls
  `AudioSyncEngine`/`SmartCropEngine` statically)
- **What's wrong:** The pure math (FFTHelper, SmartCropEngine.computeCropRect,
  LayoutEngine) is testable and tested, but every orchestration layer — reference
  selection + offset assembly, crop batch ordering, unreliable-video flow, export
  step sequencing — requires real video files and AVFoundation to execute. This is
  why CoreoTests has zero coverage of ImportViewModel, AudioSyncEngine.sync,
  SmartCropEngine.computeCropRects, and ExportEngine (see test plan).
- **Recommended change (minimal-ceremony seams, per project conventions):**
  - `AudioSyncEngine.sync(videos:extract:)` — add an injected
    `extract: (URL, Double) async throws -> [Float]` parameter defaulting to
    `AudioExtractor.extractPCM`.
  - `SmartCropEngine.computeCropRects(for:detect:)` — same pattern, default
    `PersonDetector.detectPersons`.
  - `ImportViewModel.init(syncEngine:cropEngine:)` taking small structs-of-closures
    (or protocols `AudioSyncing`/`CropComputing`) with production defaults.
  - ExportEngine: split pure planning from IO — `ExportPlan.make(project:resolution:)`
    returning insert times, scaled ranges, panel configs, bumper instruction layout
    (all value types, fully testable), consumed by a thin `ExportEngine.run(plan:)`.
- **Blast radius:** Signatures only; production call sites pass defaults.
- **Verification/test:** Unlocks ~20 tests listed in the test plan.
- **Confidence:** High.

### H7. Looping and the timeline clock are driven by the reference player, which may not span the timeline

- **Files:** `WorkspaceViewModel.swift:454-471` (`observeEndOfPlayback` on the
  reference item), `:428-448` (time observer on reference player), reference chosen
  by audio bitrate in `AudioSyncEngine.chooseReference` (not by duration)
- **What's wrong (VERIFIED logic):** `timelineEnd` is the max of all video ends, but
  (a) when the REFERENCE video ends, all players are looped back to start even if
  other angles still have content (premature loop), and (b) `currentTimeSeconds` is
  derived from the reference player's clock, so if the reference ends first the
  playhead stalls while other players keep playing (timeline freezes, no loop ever
  fires until the reference item's own end event — which fired already). The
  reference can easily be a shorter clip (bitrate criterion).
- **Recommended change:** Drive the clock from the LONGEST-spanning player
  (`argmax(offset + duration)`), or better: keep the reference clock but detect
  `currentTimeSeconds >= timelineEnd - epsilon` in the tick handler to trigger the
  loop, and observe `AVPlayerItemDidPlayToEndTime` for ALL items, looping only when
  the timeline (not any single item) is exhausted. Fold into the C1
  `PlayerSyncPlan` work — same module, same tests.
- **Blast radius:** WorkspaceViewModel.
- **Verification/test:** Pure-plan unit tests (timeline end with heterogeneous
  durations); manual check with a short high-bitrate clip + long low-bitrate clip.
- **Confidence:** High.

### H8. Trim is a stub: model fields + timeline dimming exist, but nothing can set a trim and export ignores it

- **Files:** `CoreoProject.swift:48-52` (fields), `TimelineView.swift:259-304`
  (renders trim overlay), grep VERIFIED: no writer of `timelineTrimStartSeconds`
  anywhere; `ExportEngine` has zero references to trim.
- **What's wrong:** Dead-end feature: persisted fields and 45 lines of render code
  for state that can never be non-nil, and an export that would ignore it anyway.
- **Recommended change:** Either (a) implement: add trim handles to TimelineView
  (drag brackets), and in `ExportEngine` constrain composition insertion to the trim
  window (offset `insertTime` by `-trimStart`, clamp source ranges, also remap speed
  segments/annotations), or (b) delete the fields + overlay until scheduled. Given
  DESIGN lists trim implicitly via "export exactly what you see," recommend (a) but
  as its own wave; in the interim do NOT delete model fields if H1 versioning lands
  first (additive removal is a schema change).
- **Blast radius:** TimelineView, ExportEngine, model.
- **Verification/test:** `ExportPlan` tests with trim windows (after H6 split).
- **Confidence:** High.

### H9. End-bumper temp file is deleted before the export session reads it

- **Files:** `ExportEngine.swift:264-292` (`appendEndBumper` ends with
  `try? FileManager.default.removeItem(at: bumperURL)`), export session runs later
  (:128-134, :417-482)
- **What's wrong (VERIFIED order, INFERRED failure):** The composition only holds a
  reference to the `AVURLAsset`; media data is read from disk when
  `AVAssetExportSession` runs — after the file has been unlinked. Unless AVFoundation
  happens to hold an open descriptor from the earlier `load(.duration)` (not
  guaranteed), the bumper segment will fail to read -> blank tail or export error.
  Note `print("End bumper failed, skipping")` would NOT catch this (failure happens
  during export, not append).
- **Recommended change:** Return `bumperURL` from `appendEndBumper` and delete it in
  `export`'s completion path (defer after `performExport`), alongside the existing
  output-file cleanup.
- **Blast radius:** ExportEngine only.
- **Verification/test:** Manual export; assert bumper frames present at tail. After
  H6, an `ExportPlan` test asserting cleanup happens post-session.
- **Confidence:** Medium-High (ordering is certain; AVFoundation buffering behavior
  is the only escape hatch).

### H10. Tooling gates are unenforceable: no .swiftlint.yml / .swiftformat, and the Tier-1 test command targets a nonexistent test class

- **Files:** repo root (VERIFIED: neither config file exists); CLAUDE.md testing
  tiers reference `-only-testing:CoreoTests/UnitTests` but `UnitTests` is a
  DIRECTORY — the test classes are `AnnotationModelTests`, `ModelTests`,
  `AudioSyncTests`, `LayoutEngineTests`, `TimeFormattingTests`. `-only-testing`
  matches Target/Class[/method], so Tier 1 selects nothing. Also
  `VideoPanelView.swift:205` carries a `swiftlint:disable` comment for a linter that
  has no config; `project.yml` pins `xcodeVersion: "15.0"` while the environment is
  Xcode 26.5; no `scheme:` blocks (shared schemes/coverage not pinned for CI);
  `SWIFT_VERSION: 5.9` with no `SWIFT_STRICT_CONCURRENCY` setting.
- **Recommended change:** (1) Add `.swiftlint.yml` (opt-in: `force_unwrapping`,
  `file_length: warning 500/error 800`, `function_body_length: 50/80`,
  `cyclomatic_complexity`, excluded: Coreo.xcodeproj) and `.swiftformat`
  (`--swiftversion 5.9`, indent 4, `--self remove`). (2) Fix CLAUDE.md Tier 1 to
  `-only-testing:CoreoTests` (whole target IS the fast tier today) or rename/keep a
  `UnitTests` umbrella by suite. (3) project.yml: add a shared `Coreo` scheme with
  `gatherCoverageData: true`, test target list; bump `xcodeVersion`; set
  `SWIFT_STRICT_CONCURRENCY: targeted` as a Swift-6 on-ramp. (4) Wire swiftlint/
  swiftformat as XcodeGen `postCompileScripts` or pre-commit, matching the quality
  gates already promised in CLAUDE.md.
- **Blast radius:** Build config only.
- **Verification/test:** `swiftlint --strict` and `swiftformat --lint .` run clean;
  Tier-1 command executes >0 tests.
- **Confidence:** High.

---

## MEDIUM

### M1. TimelineView sub-bars are horizontally misaligned with the gesture mapping

- **Files:** `TimelineView.swift:51-80` (children inside `.padding(.horizontal, 8)`
  but given the FULL geometry `width` for x-mapping), `:309-332` (gesture correctly
  uses `width - 16` and `x - 8`), `:263-304` (trim overlay does its own +8
  compensation, differently)
- **What's wrong (VERIFIED):** `videoCoverageBars(width:)`, `speedSegmentOverlays`,
  `scrubArea` map `timelineEnd` to `x = width` while living in a container that is
  `width - 16` wide: everything drawn is stretched ~16 pt too wide and shifted; the
  playhead can render up to 8 pt outside the padded area while the finger mapping
  uses the corrected width — visible playhead-vs-touch offset that grows toward the
  right edge.
- **Recommended change:** Extract `struct TimelineScale { let start, duration: Double;
  let width: CGFloat; func x(for seconds: Double) -> CGFloat; func seconds(forX:) -> Double }`,
  construct ONE per layout pass with the padded width, and use it for bars, playhead,
  markers, trim, and gesture. This also kills the 5-way duplication in M5.
- **Blast radius:** TimelineView (+ shared use by SpeedControlView/marker views).
- **Verification/test:** Unit tests on TimelineScale round-trip and edge mapping
  (`x(timelineEnd) == width`).
- **Confidence:** High.

### M2. ExportEngine runs the entire composition build on the main actor

- **Files:** `ExportEngine.swift:50-55` (`@MainActor static func export`), `:417-422`
  (`@MainActor performExport`)
- **What's wrong (VERIFIED):** Composition assembly, track loading loops, and the
  progress-polling loop are all pinned to the main actor; only the UIApplication
  background-task calls genuinely need it. On 6-video projects this contributes to
  UI hitching during the pre-encode phase (steps at progress 0.05-0.40).
- **Recommended change:** Make `export` nonisolated; hop to MainActor only for
  `beginBackgroundTask`/`endBackgroundTask` (or use the `UIApplication` async
  wrappers in a small `@MainActor` helper); deliver progress via
  `progressHandler` documented as main-actor (`@MainActor (Double) -> Void`),
  which WorkspaceViewModel already satisfies.
- **Blast radius:** ExportEngine + WorkspaceViewModel callback annotation.
- **Verification/test:** Compile-level; manual export responsiveness.
- **Confidence:** Medium-High.

### M3. Dead code inventory (delete or wire up)

All VERIFIED by call-site grep:
- `Coreo/Annotations/AnnotationTimeRangeControl.swift` — 220 lines, ZERO usages.
  Notably this is the DESIGN-specified UI for adjusting annotation time ranges; the
  shipped flow can only create fixed 3 s windows. Wire it into the annotation
  selection flow (selecting an annotation should present it) or delete.
- `WorkspaceViewModel.cyclePlaybackRate()` (:160-168) — never called.
- `CoreoProject.overlapStartSeconds/overlapEndSeconds` (:130-144) — used only by tests.
- `ExportEngine.applyAnnotationOverlay` (:395-413) + the entire
  `AnnotationCompositor.swift` (403 lines) — unreachable (see C2 before deleting:
  the rasterization helpers are reusable).
- `VideoAssetError.noAudioTrack` (VideoAsset.swift:14) — case never thrown since
  audio became optional.
- `ImportViewModel.selectBestAudioSource` is live, but its sibling
  `pendingSyncOutput.audioSourceIndex` already encodes the same answer for the
  include-path — one of the two argmax implementations is redundant (see M5).
- **Recommended change:** Wire AnnotationTimeRangeControl (preferred — it closes a
  spec gap); delete the rest. ~700 lines removed or activated.
- **Blast radius:** Local. **Confidence:** High.

### M4. DesignSystem exists but is bypassed: the accent color is hardcoded in 10 view files

- **Files (VERIFIED grep, 11 files contain `Color(red: 1.0, green: 0.42, blue: 0.21)`):**
  ContentView, SpeedControlView, WorkspaceView, TimelineView, TextAnnotationView,
  AnnotationTimeRangeControl, ArrowAnnotationView, AnnotationToolbar,
  ExportProgressView, ImportView — plus DesignSystem.swift where it is the canonical
  `CoreoColor.accent`. Background colors `0.04/0.1/0.06` triplets are similarly
  re-derived locally (`WorkspaceView.swift:18-21`, `TimelineView.swift:36-39`,
  `ImportView.swift:24-27`, `VideoPanelView.swift:78`, etc.), and the sync-button
  gradient re-hardcodes `accentGradientEnd` (`ImportView.swift:285-291`).
  DesignSystem.swift's own header says "Every UI file should reference these
  constants."
- **Recommended change:** Mechanical sweep: replace local `accentCoral`/`bgColor`/
  `panelBackground` constants with `CoreoColor.*`; add
  `CoreoColor.error` usage in `ImportView.errorBanner` (:318-324, currently another
  hardcoded red). Add a swiftlint custom rule banning `Color(red:` outside
  DesignSystem.swift to lock it.
- **Blast radius:** Views only, zero behavior change. **Confidence:** High.

### M5. Cross-module duplication: timeline math x5, hex parsing x3, arrowhead geometry x3, argmax-bitrate x3, panel layout x2

All VERIFIED:
- Timeline x<->seconds mapping duplicated in `TimelineView` (:113-130),
  `SpeedControlView` (:434-455), `AnnotationTimeRangeControl` (:179-191),
  `AnnotationMarkerView` (:68-73), `HoldMarkerView` (:49-53). Fix via M1's
  `TimelineScale`.
- Hex color parsing: `Color(hex:)` (AnnotationModel.swift:239-276, supports 6+8
  digit) vs two IDENTICAL private `UIColor(hexString:)` extensions
  (AnnotationCompositor.swift:17-27, AnnotationOverlayView.swift:379-389, 6-digit
  only — silently wrong alpha for 8-digit input). Consolidate into one
  `ColorHex.swift` utility with both `Color` and `UIColor` initializers + tests.
- Arrowhead geometry computed three ways: `ArrowheadShape`
  (ArrowAnnotationView.swift:153-184), `ArrowPreviewShape`
  (AnnotationOverlayView.swift:298-332 — note its perpendicular math differs
  slightly from the others), `AnnotationCompositor.arrowheadPath` (:269-303).
  Extract `ArrowGeometry.head(from:to:length:width:) -> (tip, left, right)`.
- Argmax-by-bitrate three times: `AudioSyncEngine.chooseReference` (:165-177),
  `AudioSyncEngine.sync` audio source selection (:151-152),
  `ImportViewModel.selectBestAudioSource` (:222-233).
- Panel layout + override scaling duplicated between `VideoGridView.panelRects`
  (:63-88) and `ExportEngine.buildVideoComposition` (:314-337) — including the
  WYSIWYG divergence that `gap: 4` means 4 pt in a ~390 pt-wide preview but 4 px in
  a 1920 px export (proportionally ~5x thinner). Extract
  `PanelLayoutResolver.resolve(project:containerSize:) -> [CGRect]` used by both,
  with gap expressed as a fraction of container width.
- **Blast radius:** Mostly mechanical; the gap-fraction change visibly alters export
  output (intentional fix).
- **Verification/test:** Unit tests on TimelineScale, ColorHex, ArrowGeometry,
  PanelLayoutResolver (all pure). **Confidence:** High.

### M6. AnnotationOverlayView re-decodes and re-rasterizes PKDrawings on every body evaluation

- **Files:** `AnnotationOverlayView.swift:282-292` (`drawingView(for:)` calls
  `try? PKDrawing(data:)` AND `pkDrawing.image(from:scale:)` inside `@ViewBuilder`)
- **What's wrong (VERIFIED):** Every body eval — every scrub tick while in
  annotation mode, and after C2's fix every playback tick — performs PencilKit
  deserialization plus a full-container 2x rasterization per drawing annotation.
- **Recommended change:** Cache `UIImage` per annotation id + containerSize in a
  small `@State` dictionary (or a dedicated renderer object invalidated when
  `project.annotations` changes). After C2, the same cache feeds export compositing.
- **Blast radius:** AnnotationOverlayView. **Confidence:** High.

### M7. ImportViewModel encapsulation leaks and silent error swallowing in the import flow

- **Files:** `ImportView.swift:59-66` and `:339-354` (view directly mutates
  `viewModel.pendingImports`, and orchestrates sync-triggering via
  `.onChange(of: pendingImports)`); `:346` (`try? await item.loadTransferable` —
  failure silently drops the video with no user feedback, violating the
  error-handling rule); `ImportViewModel.swift:208-219` (`computeCropOverrides`
  returns `[:]` where `nil` is the documented "no crop" sentinel; the
  `overrides.isEmpty ? [:] : overrides` expression is a no-op)
- **Recommended change:** Move pendingImports bookkeeping and the auto-sync trigger
  into VM methods (`beginImports(count:)`, `importCompleted()` -> returns
  `.readyToSync`); surface transferable failures via `syncError`; make
  `computeCropOverrides` return `[Int: CGRect]?` nil-when-empty (or fold into H3's
  per-video `cropRect`).
- **Blast radius:** Import module. **Confidence:** High.

### M8. ExportError equality hack instead of Equatable conformance

- **Files:** `WorkspaceViewModel.swift:599-606` (file-private `static func ==` on
  ExportError WITHOUT Equatable conformance, used by the
  `catch let error as ExportError where error == .cancelled` clause at :335)
- **What's wrong (VERIFIED):** Works, but the operator is invisible outside this
  file, shadows synthesized semantics, and silently matches nothing for other cases.
- **Recommended change:** `enum ExportError: Error, Equatable` in ExportEngine.swift
  (associated `String` values are Equatable); delete the private extension.
- **Blast radius:** Two files. **Confidence:** High.

### M9. ModelTests mutate the real shared Documents file; persistence has no injectable location

- **Files:** `CoreoTests/UnitTests/ModelTests.swift:232-278`,
  `CoreoProject.swift:151-158` (hardcoded `fileURL`, with a force-unwrap on
  `urls(for:).first!`)
- **What's wrong (VERIFIED):** `testSaveAndLoad` writes/deletes
  `Documents/coreo_project.json` in the test host's real container; tests are
  order-dependent with any future feature using the same path, and parallel test
  execution can race.
- **Recommended change:** As part of H1, give the store an injectable root URL
  (`ProjectStore(rootURL:)`); tests use `FileManager.temporaryDirectory` subdirs.
- **Blast radius:** Model + tests. **Confidence:** High.

### M10. Misplaced types blur module boundaries

- **Files (VERIFIED):** `AnnotationTool` enum lives in the view file
  `Annotations/AnnotationToolbar.swift:11-40` but is state held by
  WorkspaceViewModel; `FFTHelper` lives in `Utilities/` though it is sync-domain
  (only consumer: AudioSyncEngine); `VideoTransferable` inside ImportView.swift is
  fine; `LayoutOverrides` lives in CoreoProject.swift (dies with H3).
- **Recommended change:** Move `AnnotationTool` into `Annotations/AnnotationModel.swift`;
  move `FFTHelper.swift` to `Coreo/Sync/`. Dependency direction otherwise checks out
  (Models <- {Sync, Crop, Import, Workspace, Export}; UI/ leaf; no upward imports
  found).
- **Blast radius:** File moves only. **Confidence:** High.

### M11. FFT packed-format DC/Nyquist bin contamination in the spectrum multiply

- **Files:** `FFTHelper.swift:104-113`
- **What's wrong (INFERRED, standard vDSP gotcha):** `vDSP_fft_zrip` packs DC into
  `real[0]` and Nyquist into `imag[0]`. The element-wise complex multiply treats
  `(real[0], imag[0])` as one complex bin, cross-contaminating DC and Nyquist before
  the inverse FFT. For broadband audio correlation the induced error is tiny (tests
  pass with +-2-sample tolerance), but it is a real numerical defect and trivially
  fixed.
- **Recommended change:** Special-case bin 0: `productReal[0] = refReal[0]*sigReal[0];
  productImag[0] = refImag[0]*sigImag[0]` before the loop (and when applying C4's
  vDSP_zvmul fix, note vDSP_zvmul has the same caveat). Add an
  impulse-autocorrelation regression test asserting an exact peak.
- **Blast radius:** FFTHelper. **Confidence:** Medium (math VERIFIED against vDSP
  docs; practical impact small).

### M12. `finalizeProject(includeUnreliable: false)` records a wrong reference and re-uses stale offsets

- **Files:** `ImportViewModel.swift:148-188`
- **What's wrong (VERIFIED):** After filtering out unreliable videos, the project is
  built with `referenceVideoIndex: 0` while `filteredOffsets` remain relative to the
  ORIGINAL reference (which may have moved index or — if it was itself unreliable —
  been removed, leaving no zero-offset video). Timeline math survives (it uses
  min/max), but the time-observer reference player (H7) and any future offset
  editing are keyed to the wrong video.
- **Recommended change:** Recompute: find the surviving video with offset closest to
  0 (or re-normalize all offsets by subtracting the new reference's offset) and set
  `referenceVideoIndex`/`referenceVideoID` accordingly. Trivial once H3 lands
  (IDs not indices).
- **Verification/test:** Unit test with injected sync output (after H6).
- **Confidence:** High.

### M13. `print()` debugging and missing structured logging

- **Files (VERIFIED):** `CoreoApp.swift:31`, `ExportEngine.swift:102`
- **Recommended change:** `import os` + `Logger(subsystem: "com.coreo.app",
  category: "export"/"app")`; log at `.error`. Add swiftlint rule to ban `print(`.
- **Confidence:** High.

### M14. Magic numbers and divergent constants

- **Files (VERIFIED):** fade duration 0.2 defined independently in
  `AnnotationModel.swift:55-56` AND `AnnotationCompositor.swift:38` (two sources of
  truth for one visual behavior); default annotation window 3.0
  (`AnnotationModel.swift:100`); authoring reference width `375.0` twice in
  AnnotationCompositor (:172, :221); export disk floor `500_000_000`
  (ExportEngine:64); zoom limits 1.0/5.0 + rubber-band factors
  (VideoPanelView:85-112); default annotation color `"#FF6B36"`
  (WorkspaceViewModel:189) which is NOT one of the six palette entries
  (AnnotationModel:223-230) so the color picker shows no selected swatch initially;
  panel gap `4` in two call sites (VideoGridView:86, ExportEngine:335).
- **Recommended change:** Introduce `enum AnnotationConstants { static let
  fadeDuration = 0.2; static let defaultDuration = 3.0; static let
  authoringReferenceWidth: CGFloat = 375 }`, `enum ExportConstants`, and set the
  default color to `TimedAnnotation.palette` entry (or add #FF6B36 to the palette).
- **Confidence:** High.

### M15. Concurrency hygiene ahead of Swift 6

- **Files:** `AudioExtractor.swift:69-110` (Task.detached closure captures
  non-Sendable `AVURLAsset`/`AVAssetTrack`), `PersonDetector.swift:76-101` (same for
  `AVAssetImageGenerator`), `PanelCompositor`/`PanelCompositionInstruction`
  `@unchecked Sendable` (acceptable — immutable lets — but undocumented invariant),
  `WorkspaceViewModel` time-observer allocates a Task per 33 ms tick (:438-447).
- **What's wrong:** Compiles under Swift 5.9 minimal checking; will warn/error under
  targeted/complete. The per-tick Task is allocation churn and can reorder under load
  (ticks processed out of order).
- **Recommended change:** Annotate the detached closures' captured values
  (`nonisolated(unsafe) let` or restructure so loads happen before detach — tracks
  and settings are already loaded before the detach in AudioExtractor; pass plain
  values in). For the observer, since the queue is `.main`, replace
  `Task { @MainActor ... }` with `MainActor.assumeIsolated { ... }` to keep ordering
  and drop allocations. Set `SWIFT_STRICT_CONCURRENCY: targeted` (H10) to surface
  the rest.
- **Confidence:** Medium-High.

### M16. Zero SwiftUI previews; UI iteration is build-and-run only

- **Files:** VERIFIED grep — no `#Preview` / `PreviewProvider` anywhere.
- **Recommended change:** Add `#Preview` to leaf views with no VM dependency
  (Timeline subviews after M1 extraction, AnnotationToolbar, ExportProgressView,
  VideoThumbnailView, AnnotationTimeRangeControl, SpeedControlView popup) using
  small fixture builders (`CoreoProject.preview2Videos`). Requires the fixture
  factory proposed in the test plan anyway.
- **Confidence:** High.

---

## LOW

### L1. `WorkspaceViewModel.togglePlayback` resumes without awaiting seek completion
`WorkspaceViewModel.swift:121-132` — `seekAll` issues async `player.seek` and
`playAll` runs immediately; players can start a few frames apart on resume. Use the
completion-handler/async `seek` and gate `playAll` on all completions. INFERRED minor
drift; fold into C1 work.

### L2. EndBumperGenerator busy-waits on `isReadyForMoreMediaData`
`EndBumperGenerator.swift:90-114` — 10 ms sleep polling instead of
`requestMediaDataWhenReady(on:)`. Works for 30 frames; replace if touched.

### L3. DocumentPicker `supportedTypes` redundancy
`DocumentPickerView.swift:17-21` — `.movie` already subsumes `.mpeg4Movie` and
`.quickTimeMovie`.

### L4. Imported temp files are never cleaned up
`ImportView.swift:361-377` — VideoTransferable copies into tmp with UUID names;
removed videos' files linger until OS purge. Becomes moot under H1 (project-owned
media directory with delete-on-remove).

### L5. `VideoAsset.thumbnailData` inflates persisted JSON
Base64 thumbnail inside project.json (with `.prettyPrinted`!). Under H1, store
thumbnails as files in the project directory; also drop `.prettyPrinted` from the
production encoder.

### L6. Haptic generators never `prepare()`d
`Haptics.swift` — first-use latency; call `prepare()` on creation or before
expected use. Cosmetic.

### L7. `TimeFormatting.format` centisecond-carry path untested
`TimeFormatting.swift:25-28` — the `centiseconds >= 100` recursive carry
(e.g. `format(0.999)` -> "0:01.00") has no test; add one (it is correct, lock it).

### L8. `AVPlayerLayerView.applyCropMask` allocates a new CAShapeLayer every update
`VideoPanelView.swift:171-190` — already tracked as deferred in PERFORMANCE.md;
becomes moot if H2 replaces the mask approach.

### L9. Test framework: XCTest only
Project conventions prefer Swift Testing (`@Test`/`#expect`) for NEW tests. Keep
existing XCTest files; write new suites with Swift Testing (Xcode 26 supports mixed
targets). Low priority, zero migration urgency.

### L10. `ExportProgressView.statusText` thresholds duplicate ExportEngine's progress constants
Magic 0.05/0.20/0.35/0.45/0.95 mirror the hardcoded progress checkpoints in
`ExportEngine.export`. If export steps change, the status strings lie. Define a
shared `ExportPhase` enum mapped from progress, or have the engine report a phase.

---

## TEST PLAN (prioritized, file-by-file)

Current inventory: 5 files / ~74 tests, all pure-logic, all XCTest:
- `AnnotationModelTests` (opacity, defaultTimeRange, Codable, Color hex) — good.
- `ModelTests` (VideoAsset/CoreoProject Codable, timeline math, save/load) — good,
  but save/load pollutes real Documents (M9).
- `AudioSyncTests` (FFTHelper offsets incl. negative lag + SmartCropEngine geometry)
  — good quality, realistic composite-wave fixtures.
- `LayoutEngineTests` (counts, overlap, gaps, edge cases) — good.
- `TimeFormattingTests` — thorough.

Zero coverage: SpeedSegment/SpeedMap, WorkspaceViewModel (all playback math),
ImportViewModel, AudioSyncEngine.sync orchestration, SmartCropEngine.computeCropRects,
ExportEngine, PanelCompositor, AnnotationCompositor, EndBumperGenerator,
AudioExtractor, PersonDetector, CoreoProject.sanitizeIndices.

Priority order (each entry: new file -> contents -> which finding it locks):

1. **`CoreoTests/UnitTests/SpeedMapTests.swift`** — `rate(at:)` (no segment -> 1.0;
   boundary inclusive-start/exclusive-end; overlapping segments -> latest-start
   precedence), `addSegment` (no-overlap keep; full containment removal; left-trim;
   right-trim; both-sides split producing left+right remnants), `removeSegment`,
   hold semantics (`isHold` iff rate==0). Pure structs, no fixtures needed.
   Locks C3's mapper groundwork; highest value-per-line in the repo.
2. **`CoreoTests/UnitTests/PlaybackMathTests.swift`** — after extracting pure helpers
   from WorkspaceViewModel (C1/H7): `videoTime(forTimeline:offset:)` clamping,
   `isVideoActive`, `inactiveLabel` strings, `clampToTimeline`, PlayerSyncPlan
   activation transitions (inactive->active seeks to exact content time — the C1
   regression lock), loop trigger at timelineEnd with heterogeneous durations (H7).
3. **`CoreoTests/UnitTests/TimelineScaleTests.swift`** — after M1 extraction:
   x<->seconds round-trip, `x(timelineEnd) == width`, zero-duration guards, padded
   alignment (locks M1, M5).
4. **`CoreoTests/UnitTests/AudioSyncEngineTests.swift`** — after H6 seam: injected
   extractor returning canned arrays — reference = highest bitrate; offsets array has
   0 at reference; results sorted by index; one extractor throwing `.noAudioTrack`
   -> flagged unreliable not thrown (locks H5); audio-source argmax; <2 videos throws.
5. **`CoreoTests/UnitTests/ExportPlanTests.swift`** — after H6 split: insert time =
   `offset - timelineStart`; speed scaling arithmetic (2 s at 0.5x -> 4 s); hold ->
   single-frame scale of holdDuration (locks C3 export); trim windowing (locks H8);
   bumper instruction covers `[mainDuration, total]` only when bumper succeeded;
   panel rect resolution parity with PanelLayoutResolver (locks M5 WYSIWYG).
6. **`CoreoTests/UnitTests/CoreoProjectMigrationTests.swift`** — decode checked-in v1
   fixture JSON string; `schemaVersion` default; corrupt-file -> distinct error not
   nil (locks H1/H3; THE regression gate for the data-model reshape).
7. **`CoreoTests/UnitTests/AnnotationRenderMathTests.swift`** — make
   `buildOpacityAnimation` internal (or test the replacement per-frame alpha
   function from C2): keyTimes strictly nondecreasing in [0,1], values match
   `opacity(at:)` at sampled times, persistent -> constant 1, zero-duration timeline
   guard. Plus `ArrowGeometry` head-point math (locks M5).
8. **`CoreoTests/UnitTests/PanelCompositorTests.swift`** — `orientation(from:)` for
   the four standard transforms + identity-with-translation; (after H2) crop-rect ->
   image-space mapping math.
9. **`CoreoTests/UnitTests/ImportViewModelTests.swift`** — after H6/M7: injected
   engines; unreliable flow parks output + populates names; `finalizeProject(false)`
   re-normalizes reference (locks M12); <2 survivors -> error; pendingImports
   lifecycle.
10. **`CoreoTests/UnitTests/ColorHexTests.swift`** — consolidate existing Color-hex
    tests; add UIColor path + 8-digit alpha through the unified utility (locks M5).
11. **Augment `AudioSyncTests`** — FFT impulse autocorrelation exact-peak test
    (locks M11/C4 vDSP changes); `crossCorrelate` empty-input contract.
12. **`EndBumperGeneratorTests`** — `opacityForFrame` fade curve (make internal).
13. **Shared fixtures** — `CoreoTests/Fixtures/ProjectFixtures.swift`:
    `makeVideo(duration:bitrate:)`, `makeProject(offsets:)` builders to replace the
    ~8 copies of inline VideoAsset construction in ModelTests/future tests; doubles
    as the `#Preview` data source (M16).

Integration tier (deferred until xcodebuild is fixed): tiny bundled 2-second test
clips (silent + tone) exercising AudioExtractor end-to-end, full ExportEngine smoke
on simulator, PersonDetector on a synthetic frame. Wire as a separate
`CoreoIntegrationTests` class so Tier 1 stays fast (and fix the Tier-1 selector, H10).

---

## TOP 10 (one-liners, priority order)

1. **C1** Fix permanent desync of late-starting videos in live playback (pause/activate players per timeline position; extract testable PlayerSyncPlan).
2. **C2** Make annotations actually appear: always-mounted read-only overlay during playback + render annotations inside PanelCompositor for export.
3. **C3** Fix holds: scheduled resume in live playback; export freeze via single-frame scaleTimeRange instead of black insertEmptyTimeRange.
4. **C4** Re-apply the six "fixed" perf/edge-case changes that are absent from code (AudioExtractor pool/capacity/copy, vDSP_zvmul, sync cancellation, no-audio filtering) and correct the docs.
5. **H1+H3** Reshape the data model (per-video syncOffset/crop/panel + UUID refs + schemaVersion + project-directory store with relative media paths) and actually wire save/load — migration is free today, costly later.
6. **H6** Add closure/protocol seams to AudioSyncEngine, SmartCropEngine, ImportViewModel, and split ExportEngine into pure ExportPlan + IO runner — unlocks the entire test plan.
7. **H2** Make smart-crop real: honor cropRect in PanelCompositor and replace the preview mask with proper crop-zoom (shared pure mapping function).
8. **H7+H9+H8** Export/playback correctness batch: loop on timeline end not reference end; delete bumper temp file after export; implement or remove trim.
9. **H4** Split the 606-line / 17-@Published WorkspaceViewModel (PlaybackController / AnnotationStore / ExportCoordinator) to kill 30 Hz whole-tree invalidation.
10. **H10+M1+M5** Tooling + dedup wave: swiftlint/swiftformat configs, fix Tier-1 test selector, scheme+coverage in project.yml; extract TimelineScale/ColorHex/ArrowGeometry/PanelLayoutResolver and route all views through DesignSystem tokens.

---

## For JMT (decisions needing you / device)

- **iOS 16 vs 17 minimum:** Staying at 16 blocks `@Observable` (the cleanest fix for
  the 30 Hz invalidation) and keeps the deprecated single-param `onChange`. If 17+ is
  acceptable for a 2026 launch, say so before the H4 wave — it changes the refactor
  shape.
- **Single-project vs project library:** DESIGN says "projects are self-contained
  directories" but the UI has no project list. H1 builds the directory store either
  way; whether a picker screen is wanted determines if `ContentView` grows a third
  screen.
- **Annotation-during-playback UX and export gap fraction (M5):** both change visible
  output; quick device check recommended after the waves land.
- **Bumper:** it currently brands every export with a 1 s "Coreo" card; confirm
  that's still desired for a paid app (some users resent watermark-adjacent tails).
