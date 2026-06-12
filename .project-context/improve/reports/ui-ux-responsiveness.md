# Coreo UI/UX Survey -- Smoothness, Responsiveness & Feedback

Survey agent lens: UI/UX responsiveness, progress/feedback, scrubbing feel, states,
animation, gestures, layout, accessibility, taste-based affordances.
Method: static analysis only (xcodebuild broken on this machine). Every claim labeled
VERIFIED (read in code) or INFERRED (requires device/runtime confirmation).
Line numbers refer to the working tree as of 2026-06-11 (commit 9346ce5 + untracked Coreo/).

Severity scale: Critical = core flow broken or trust-destroying; High = visible jank,
missing promised feedback, or flow trap; Medium = polish/HIG/DESIGN divergence; Low = nice-to-have.

---

## CRITICAL

### C1. Annotation creation is unreachable -- the toolbar never enters annotation mode
- **Files:** `Coreo/Annotations/AnnotationToolbar.swift:98-118` (toolButton action is only
  `selectedTool = tool`), `Coreo/Workspace/WorkspaceViewModel.swift:195-201`
  (`enterAnnotationMode` exists), `Coreo/Workspace/TimelineView.swift:73-76` (the ONLY caller),
  `Coreo/Workspace/WorkspaceView.swift:50-55` (overlay mounted only when `isAnnotationMode`).
- **What's wrong (VERIFIED):** `isAnnotationMode` is set to true in exactly one place: tapping an
  existing annotation marker on the timeline. Markers only exist once annotations exist.
  Tapping pencil/text/arrow/eraser in the edit tools panel changes `selectedAnnotationTool` but
  never sets `isAnnotationMode`, so `AnnotationOverlayView` is never mounted and no tap/draw
  surface exists. **The user can never create their first annotation.** The flagship feature is
  dead in the UI. (Grep: `enterAnnotationMode` called only at TimelineView.swift:75;
  `isAnnotationMode = true` only at WorkspaceViewModel.swift:197.)
- **Recommended change:** In `AnnotationToolbar.toolButton`, call
  `viewModel.enterAnnotationMode(tool: tool)` (the view model is already passed in). Add
  `Haptic.tick()` there (UI-POLISH.md promises it). Show the Done button only while
  `viewModel.isAnnotationMode`. Optionally also auto-enter annotation mode with `.pencil` when
  the edit panel opens.
- **Blast radius:** AnnotationToolbar.swift, WorkspaceViewModel.swift. No model changes.
- **Verification:** UI test: open edit panel, tap pencil, draw a stroke, tap Save Drawing,
  assert `project.annotations.count == 1`. Unit test: `enterAnnotationMode(tool:)` sets both
  published vars and pauses playback.
- **Confidence:** High.

### C2. Annotations never render during normal playback -- overlay only mounted in annotation mode
- **Files:** `Coreo/Workspace/WorkspaceView.swift:49-56` (`if viewModel.isAnnotationMode {
  AnnotationOverlayView(...) }`), `Coreo/Annotations/AnnotationOverlayView.swift:31-35`
  (comment says "Render all visible annotations (always, regardless of mode)" -- but the parent
  never mounts it outside the mode).
- **What's wrong (VERIFIED):** DESIGN.md ("When NOT in annotation mode: Annotations fade in and
  out at their designated times during normal playback") is not implemented. The time-range
  fade logic (`TimedAnnotation.opacity(at:)`, AnnotationModel.swift:46-76) exists and is correct,
  but during playback the overlay does not exist in the view tree. Users place a note, hit play,
  and the note never appears. Combined with C-equivalent export gap (H4), annotations are
  invisible everywhere except while actively editing.
- **Recommended change:** Mount `AnnotationOverlayView` unconditionally in WorkspaceView's ZStack
  (it already gates hit-testing with `.allowsHitTesting(viewModel.isAnnotationMode)` and only
  shows tool layers in mode). Keep the creation `toolLayer` gated on `isAnnotationMode`.
- **Blast radius:** WorkspaceView.swift (one-line structural change). Must land together with M7
  (PKDrawing rasterization caching), otherwise drawings re-rasterize at 30 Hz during playback.
- **Verification:** UI test: create text annotation at t, exit mode, play; assert annotation view
  exists at t and not at t+5s. Snapshot test of fade opacity at range edges.
- **Confidence:** High.

### C3. A live Hold segment permanently freezes playback (no resume mechanism)
- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift:513-529` (`applyLiveSpeedSegment`),
  `:434-448` (time observer drives it), `Coreo/Speed/SpeedControlView.swift:388-402`
  (holds created with rate 0, duration 0.01s).
- **What's wrong (VERIFIED):** When the playhead enters a hold segment, `applyLiveSpeedSegment`
  pauses all players but leaves `isPlaying == true`. The periodic time observer only fires while
  the reference player's time advances, so once paused there are no further ticks, no timer is
  scheduled for `holdDurationSeconds`, and nothing ever resumes playback. The app freezes on that
  frame forever. Even pause/play recovery re-enters the same 0.01s window and re-freezes --
  the user is hard-stuck until they scrub past it or delete the segment. The play button still
  shows "pause" (isPlaying true), so the UI also lies about state.
- **Recommended change:** In the hold branch, pause players and schedule a `Task` /
  `DispatchQueue.main.asyncAfter` for `holdDurationSeconds` that (a) seeks just past
  `segment.endTimeSeconds`, (b) restores `player.rate = playbackRate * 1.0`, (c) clears
  `currentSegmentRate`. Cancel the pending resume task on pause/seek/tearDown. Show a brief
  "Hold 2s" chip overlay during the freeze so the freeze reads as intentional.
- **Blast radius:** WorkspaceViewModel.swift only.
- **Verification:** Unit test with a fake clock is hard against AVPlayer; minimum: unit-test the
  hold-resume scheduling state machine extracted into a testable helper; manual device test:
  place Hold 2s, play through it, assert playback resumes.
- **Confidence:** High.

### C4. Back navigation from Workspace is a dead end -- the user can never re-enter
- **Files:** `Coreo/Import/ImportView.swift:165-176` (sync UI shown only when
  `isSyncing` or `syncError != nil`), `:68-76` (auto-sync only fires on `pendingImports`
  transition to 0), `Coreo/App/ContentView.swift:16-28`.
- **What's wrong (VERIFIED):** After a successful sync the app navigates to Workspace. If the
  user taps back (e.g., to check something), `currentProject` is cleared and ImportView shows
  its populated state with thumbnails -- but the "Sync & Go" button renders only when
  `syncError != nil`, and the auto-sync `onChange(of: pendingImports)` will not re-fire. There is
  no button, no spinner, no path back to the workspace. The user must remove and re-add a video
  to retrigger sync (recomputing sync + person detection from scratch and discarding any prior
  workspace edits, which are unsaved anyway -- see H1).
- **Recommended change:** Show the Sync button whenever `viewModel.canSync && !viewModel.isSyncing`
  (restore DESIGN.md's explicit button; see H3). Better: keep the last successful `CoreoProject`
  in ImportViewModel and show a "Continue" button that re-opens it without re-syncing.
- **Blast radius:** ImportView.swift, ImportViewModel.swift, ContentView.swift.
- **Verification:** UI test: import 2 videos, auto-enter workspace, tap back, assert a tappable
  Sync/Continue control exists and re-enters workspace.
- **Confidence:** High.

### C5. Unified timeline is anchored to the reference player -- head/tail regions are unplayable and the loop truncates
- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift:428-448` (clock = reference player's
  periodic observer), `:454-471` (loop on reference item's `DidPlayToEndTime`), `:534-540`
  (`videoTime` clamps negative to 0).
- **What's wrong (VERIFIED, static reasoning):** The master clock is the reference player's
  position plus its offset. Consequences:
  1. If any video starts before the reference (negative offset, fully possible from
     cross-correlation), the timeline region `[timelineStart, refStart)` cannot play: on play,
     the reference (clamped to its own 0) starts advancing immediately, so `currentTimeSeconds`
     jumps over the pre-roll and the earlier angle's head is silently skipped.
  2. When the reference video ends before the latest-ending video, `AVPlayerItemDidPlayToEndTime`
     fires and loops everything back to `timelineStart` -- the tail where other angles still
     have content is never played. Scrubbing into the tail and pressing play immediately
     re-triggers the end notification and snaps back to the start.
  3. The "Starts in 0:04" / "Ended" panel labels (WorkspaceViewModel.swift:382-394) advertise
     coverage the engine can't actually traverse.
- **Recommended change (data-flow reshape, in scope per FULL OVERRIDE):** Drive the timeline from
  an independent clock. Options: (a) keep a per-tick `CACurrentMediaTime()`-based master clock
  (or CADisplayLink, see M6) advanced by `playbackRate` while playing, and slave all players to
  it (pause players whose local time is out of range, start them when the clock enters their
  coverage); or (b) cheaper interim: anchor the observer to the video with the earliest offset
  AND switch looping to compare `currentTimeSeconds >= timelineEnd` instead of item-end
  notifications. Option (a) is the correct fix and also gives drift correction (H8) a home.
- **Blast radius:** WorkspaceViewModel only (players, observer, loop). Timeline UI unchanged.
- **Verification:** Unit tests on the clock mapping with synthetic offsets (negative offset,
  short reference). Device test: 2 clips where reference starts 3s late -- assert pre-roll plays.
- **Confidence:** High for the truncation/skip mechanics; exact on-device feel INFERRED.

---

## HIGH

### H1. No persistence wiring at all -- all annotations/speed/layout work is silently lost
- **Files:** `Coreo/Models/CoreoProject.swift:160-186` (save/load implemented),
  grep: `.save()` / `CoreoProject.load` are called NOWHERE in app code.
- **What's wrong (VERIFIED):** Back-swipe, app kill, or a crash discards every annotation, speed
  segment, audio choice, and crop override with zero warning. DESIGN.md specifies project
  persistence in Documents. The back button (WorkspaceView.swift:112-125) doesn't even confirm.
- **Recommended change:** Call `try? viewModel.project.save()` on every mutating action (debounced)
  or at minimum in `tearDown()` and on `didEnterBackground`; on launch, if `CoreoProject.load()`
  returns a project whose video files still exist, offer "Resume last session" on ImportView.
- **Blast radius:** WorkspaceViewModel, ImportView, CoreoApp. Schema versioning is a prerequisite
  flagged in EDGE-CASES.md.
- **Verification:** Unit test save/load round-trip already possible; UI test: annotate, background
  app, relaunch, assert resume affordance.
- **Confidence:** High.

### H2. Import has zero in-progress feedback -- big videos copy silently
- **Files:** `Coreo/Import/ImportView.swift:33-39` (empty vs populated keyed only on
  `videos.isEmpty`), `:339-354` (photo items: `loadTransferable` copies whole file),
  `ImportViewModel.swift:32` (`pendingImports` published but never rendered).
- **What's wrong (VERIFIED):** After picking videos, the picker dismisses and -- until the first
  `VideoAsset.from` completes (file copy + metadata + thumbnail; seconds for large 4K clips) --
  the screen shows the untouched empty state ("Add Videos") or a stale thumbnail row. No spinner,
  no skeleton tiles, no count. Users will re-tap import or assume the pick failed.
- **Recommended change:** When `pendingImports > 0`, render N placeholder tiles (shimmer rectangles,
  80x100, matching `addTileButton` size) in the thumbnail row and a small "Importing 2 videos..."
  line; in empty state, replace the CTA block with the same. UI-POLISH.md already defers
  "thumbnail shimmer placeholder" -- this is that, plus the row-level placeholder.
- **Blast radius:** ImportView.swift only.
- **Verification:** UI test with a slow Transferable stub; assert placeholder count == pending.
- **Confidence:** High.

### H3. Sync phase: indeterminate, mislabeled, non-cancellable, and auto-navigates without consent
- **Files:** `Coreo/Import/ImportView.swift:68-76` (auto-sync on import settle), `:301-313`
  (spinner with "Syncing audio..."), `ImportViewModel.swift:96-140` (`sync()`), `:194-204`
  (`buildProject` awaits `computeCropOverrides` -- 3-7s/video per PERFORMANCE.md -- still under
  the same spinner), `:79-83` (`removeVideo` not guarded during sync).
- **What's wrong (VERIFIED):**
  1. The whole pipeline (audio extraction + FFT + person detection) shows one indeterminate
     spinner labeled "Syncing audio...", even during the multi-second person-detection phase.
     For 6 long clips this is easily 10-30s of unexplained wait. No determinate progress, no
     phase text, no cancel.
  2. DESIGN.md specifies an explicit, pulse-animated Sync button; the implementation auto-syncs
     and auto-navigates the instant `pendingImports` hits 0. A user who wants to add a second
     batch (Files then Photos) is yanked into the workspace mid-flow.
  3. `removeVideo(at:)` during an in-flight sync mutates `videos` while `sync()`'s output still
     indexes the old array; `buildProject` then pairs current `videos` with stale `output.offsets`
     (count mismatch -> `timelineEndSeconds` returns 0 -> zero-length timeline workspace).
- **Recommended change:** (a) Restore the explicit "Sync & Go" button whenever `canSync` (also
  fixes C4); keep auto-sync at most as an opt-in. (b) Make the progress view two-phase with real
  fractions: AudioSyncEngine and SmartCropEngine both loop over videos -- thread a
  `progress: (Double) -> Void` callback through (sync 0-0.6, crop 0.6-1.0), show "Analyzing
  audio (2/4)..." / "Finding dancers (3/4)...". (c) Add a Cancel button that cancels the Task
  (engines already call `Task.checkCancellation`). (d) Disable thumbnail remove buttons while
  `isSyncing`, or cancel+restart sync on removal. (e) `Haptic.success()` on sync complete,
  `Haptic.error()` on sync failure (UI-POLISH.md's haptic map claims sync-failure error haptic
  exists -- it does not; grep shows no Haptic call in ImportViewModel).
- **Blast radius:** ImportView, ImportViewModel, AudioSyncEngine, SmartCropEngine signatures.
- **Verification:** Unit: progress callback monotonicity; cancel mid-sync leaves `videos` intact
  and `isSyncing == false`. UI: remove-during-sync disabled.
- **Confidence:** High.

### H4. Annotations silently dropped from export while the progress UI says "Adding annotations..."
- **Files:** `Coreo/Export/ExportEngine.swift:120-125` (annotation overlay skipped; known
  compositor incompatibility), `Coreo/Export/ExportProgressView.swift:112-114` (status text
  literally shows "Adding annotations..." at 35-45%).
- **What's wrong (VERIFIED):** The user's annotations -- the paid differentiator -- are absent
  from the exported file, and the progress card affirmatively claims they're being added. This is
  trust-destroying: a dancer annotates 20 cues, exports, shares, and discovers the notes are gone.
- **Recommended change (UI side; the compositor fix is the export lens's item):**
  1. Remove the "Adding annotations..." status string until annotation export works.
  2. If `!project.annotations.isEmpty`, show a confirmation alert before export: "Annotations
     aren't included in exports yet. Export anyway?" -- or better, prioritize integrating
     annotation rendering into `PanelCompositor` (rasterize the annotation layer per frame time;
     the per-annotation opacity function already exists in `TimedAnnotation.opacity(at:)`).
- **Blast radius:** ExportProgressView, WorkspaceViewModel.startExport (alert), eventually
  PanelCompositor.
- **Verification:** UI test: project with annotations -> tap export -> assert warning appears.
- **Confidence:** High.

### H5. Export Cancel doesn't cancel the AVAssetExportSession -- the spinner disappears but the export keeps burning CPU
- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift:346-349` (`cancelExport` cancels the Swift
  Task only), `Coreo/Export/ExportEngine.swift:455-466` (no `Task.isCancelled` checks around
  `await exportSession.export()`, no `exportSession.cancelExport()`).
- **What's wrong (VERIFIED; also admitted in EDGE-CASES.md "Task cancellation cancels the Swift
  Task but not the underlying AVAssetExportSession"):** After Cancel, the session keeps encoding
  (battery/thermals on a 3-min 1080p export), the temp file may still be written, and a second
  export can run concurrently with the zombie one.
- **Recommended change:** Use `withTaskCancellationHandler { await exportSession.export() }
  onCancel: { exportSession.cancelExport() }` inside `performExport`; delete the partial file in
  the `.cancelled` branch (already done) and assert `isExporting` only goes false after the
  session reaches a terminal state.
- **Blast radius:** ExportEngine.performExport only.
- **Verification:** Device test: start export, cancel at ~30%, observe CPU drops and temp dir has
  no growing file. Unit-testable if session is wrapped behind a protocol.
- **Confidence:** High.

### H6. Scrub seek storm: zero-tolerance seeks on every drag tick across all players
- **Files:** `Coreo/Workspace/TimelineView.swift:309-332` (drag onChanged -> `viewModel.seek` at
  UITouch rate), `WorkspaceViewModel.swift:137-145` (`seek` issues `seek(to:toleranceBefore:.zero,
  toleranceAfter:.zero)` on every player every call).
- **What's wrong (VERIFIED design, INFERRED magnitude):** During a drag at 60-120 Hz, each tick
  issues 2-6 frame-accurate seeks. Zero tolerance forces a full GOP decode per seek per player.
  AVPlayer does cancel superseded seeks, but the decode pipeline still chokes; with 4-6 HD
  players the scrub preview will visibly lag the finger and stutter. There is also no
  completion-based coalescing (issue next seek only after the previous lands).
- **Recommended change:** In `seek(to:)`, add an `isScrubbing` flag (set by TimelineView drag):
  during drag use `toleranceBefore/After: .positiveInfinity` (or ~0.25s) and a per-player
  in-flight guard (skip issuing a new seek until the previous completion fires, storing only the
  latest target); on `onEnded`, issue one final zero-tolerance seek. Optionally scrub only the
  largest/reference panel live and snap others on release.
- **Blast radius:** WorkspaceViewModel.seek, TimelineView gesture.
- **Verification:** Instruments (Time Profiler / AVPlayer stalls) before/after on a 4-video
  project; UX check: playhead-to-finger latency.
- **Confidence:** High that it's the right pattern; severity INFERRED pending device test.

### H7. Timeline geometry mismatch: playhead/coverage/speed overlays drawn in a different coordinate frame than the gesture, markers, and trim
- **Files:** `Coreo/Workspace/TimelineView.swift:51-80` (content VStack has
  `.padding(.horizontal, 8)`), `:53,57,61` (`videoCoverageBars/speedSegmentOverlays/scrubArea`
  all receive the FULL `geometry.size.width`), `:113-117` (`xPosition` maps fraction*width),
  `:266-311` (trim overlay and drag gesture correctly use `width - 16` and `x - 8`).
- **What's wrong (VERIFIED):** The bars and playhead render inside an 8pt-padded container but
  compute x positions against the unpadded width, so at the right end of the timeline the
  playhead and coverage bars draw up to 16pt past where the finger/gesture math (and the
  annotation-marker row, which uses its own padded GeometryReader) place the same timestamp.
  Visible symptoms: playhead overhangs the rounded card at the end, annotation marker dots don't
  line up under the playhead, "played" fill overshoots.
- **Recommended change:** Pass `width - 16` into all three subviews (or drop the inner padding
  and bake an 8pt inset into a single shared `xPosition(seconds, usableWidth)`); one coordinate
  helper, used by render AND gesture AND markers AND trim.
- **Blast radius:** TimelineView.swift only.
- **Verification:** Unit test the converter; snapshot test playhead at t == timelineEnd stays
  inside bounds and aligns with a marker at the same t.
- **Confidence:** High.

### H8. No drift correction between players; stalls silently desync angles
- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift:399-422` (`automaticallyWaitsToMinimize
  Stalling = false`, no boundary/stall observation), PERFORMANCE.md ("No periodic drift re-sync
  ... user must pause/play to re-sync").
- **What's wrong (VERIFIED admission + static):** Each AVPlayer free-runs after `playAll()`. Rate
  changes, hold recovery, stalls (more likely with `automaticallyWaitsToMinimizeStalling=false`),
  and clock skew accumulate visible lip-sync/beat drift between panels -- fatal for the product's
  one job (frame-comparable angles). There is also no buffering indicator when a panel stalls;
  it just freezes while others play.
- **Recommended change:** Every ~1s during playback, compare each player's
  `currentTime() + offset` to the master clock; if `abs(delta) > 0.05s`, re-seek that player
  (tolerance ~0.02s) or use `AVPlayer.setRate(_:time:atHostTime:)` for phase-locked starts in
  `playAll()` (all players start at a shared host time -- the canonical multi-player sync API).
  Pairs naturally with the C5 clock refactor.
- **Blast radius:** WorkspaceViewModel playback section.
- **Verification:** Device test: 6 panels, 2x rate, 3 minutes; measure inter-panel offset via
  burned-in timecode clip.
- **Confidence:** High (mechanism); magnitude INFERRED.

### H9. Audio session activates at app launch -- kills the dancer's background music before any video plays
- **Files:** `Coreo/App/CoreoApp.swift:26-33` (`setCategory(.playback)` + `setActive(true)` in
  `init`), PERFORMANCE.md deferred item "Audio session active at launch, never deactivated".
- **What's wrong (VERIFIED):** A non-mixable `.playback` session activated at process start stops
  Spotify/Apple Music the moment the app opens -- before import, before any playback. Target user
  is mid-practice with music on; this is exactly the wrong default. Session is also never
  deactivated, so music doesn't resume after leaving the app.
- **Recommended change:** Remove activation from app init. Activate lazily in
  `WorkspaceViewModel.playAll()` (first play), deactivate with
  `.notifyOthersOnDeactivation` in `tearDown()`/on background. While on ImportView the session
  should stay inactive.
- **Blast radius:** CoreoApp.swift, WorkspaceViewModel.
- **Verification:** Device: play Music app, open Coreo -> music keeps playing; press play in
  workspace -> music ducks/stops; leave workspace -> music resumes.
- **Confidence:** High.

### H10. Manual sync nudge is missing entirely (DESIGN-promised fallback for bad sync)
- **Files:** DESIGN.md section 2 ("per-video fine-tune slider +/-2s, 0.01s increments" in edit
  tools); `Coreo/Workspace/WorkspaceView.swift:180-224` (edit panel has Speed/Audio/Aspect only).
- **What's wrong (VERIFIED):** When auto-sync is slightly off (the documented <5% case) or the
  user accepted an "unreliable" video, there is no remedy in the app -- offsets are immutable
  after import. The unreliable-video alert (ImportView.swift:77-94) offers Include/Remove but
  including gives a possibly-wrong offset with no way to fix it.
- **Recommended change:** Add a "Sync" row in the edit panel: per-video slider or stepper
  (+/-2s, 0.01 step) writing `project.syncOffsets[i]`, with live re-seek of that player so the
  user can nudge while watching, and a "reset to auto" button. Show the per-video confidence
  score here (currently computed and discarded -- `SyncResult.confidence` never reaches the UI
  except via the alert text).
- **Blast radius:** WorkspaceView edit panel, WorkspaceViewModel (setOffset + reseek), project
  mutation.
- **Verification:** Unit: nudging offset shifts `videoTime(forTimeline:)` mapping; UI: slider
  visible per video.
- **Confidence:** High.

---

## MEDIUM

### M1. AnnotationTimeRangeControl is dead code -- no way to adjust an annotation's visible window or "Show always"
- **Files:** `Coreo/Annotations/AnnotationTimeRangeControl.swift` (full, polished implementation;
  grep shows zero instantiations), DESIGN.md annotation-mode spec (range control + Show always
  toggle are core flow).
- **VERIFIED.** Every annotation is stuck with the default 3s window; `isPersistent` is never
  settable. **Change:** when `viewModel.selectedAnnotationID != nil` (or right after creating an
  annotation), present `AnnotationTimeRangeControl` bound to that annotation's
  `startTimeSeconds/durationSeconds/isPersistent` below the timeline (it was sized for exactly
  that). Wire bindings through WorkspaceViewModel helpers. **Blast radius:** WorkspaceView,
  WorkspaceViewModel, no model change. **Verify:** UI test dragging handles updates the model.
  Confidence: High.

### M2. Annotation marker dots: 6pt hit targets inside a scrub gesture -- effectively untappable
- **Files:** `Coreo/Annotations/AnnotationMarkerView.swift:46-54` (6pt circle + onTapGesture),
  `Coreo/Workspace/TimelineView.swift:85` (parent `DragGesture(minimumDistance: 0)` over the
  whole 80pt strip).
- **VERIFIED (size) / INFERRED (gesture arbitration on device):** UI-POLISH.md already defers
  this. A 6pt dot fails HIG 44pt; and any near-miss becomes a scrub+pause. **Change:** give each
  marker a 44x24 transparent `contentShape` hit area (dots can stay 6-8pt visually); space
  overlapping markers; consider `.highPriorityGesture` for the tap so it beats the scrub drag;
  add `Haptic.tick()` on marker jump. **Blast radius:** AnnotationMarkerView, TimelineView.
  **Verify:** device tap test; XCUITest tap accuracy. Confidence: High on fix shape.

### M3. Marker tap enters annotation mode with the toolbar hidden -- invisible-mode trap
- **Files:** `Coreo/Workspace/TimelineView.swift:73-76` (calls `enterAnnotationMode()`
  regardless of `isEditToolsVisible`), `WorkspaceView.swift:36-39` (toolbar lives inside the
  collapsed edit panel).
- **VERIFIED:** With edit tools collapsed, tapping a marker pauses video, mounts the full-screen
  annotation overlay (which intercepts ALL touches per `.allowsHitTesting(true)`), and shows no
  toolbar, no Done, no visual indication of the mode. Panels stop responding to pinch/tap; the
  escape is non-obvious (open edit panel, tap Done). **Change:** `enterAnnotationMode` should set
  `isEditToolsVisible = true` (with animation); conversely Done could collapse what it opened.
  **Blast radius:** WorkspaceViewModel. **Verify:** UI test: marker tap -> toolbar visible.
  Confidence: High.

### M4. Unsaved pencil strokes silently discarded; "Save Drawing" is an undiscoverable extra step
- **Files:** `Coreo/Annotations/AnnotationOverlayView.swift:69-107` (strokes live in local
  `@State currentDrawing`; only the "Save Drawing" button commits), `WorkspaceView.swift:141-143`
  (closing edit tools exits annotation mode -> overlay unmounts -> strokes gone).
- **VERIFIED:** DESIGN.md's flow auto-commits on Done; here, Done/edit-collapse/tool-switch can
  destroy a drawing with no warning. **Change:** commit `currentDrawing` automatically in
  `exitAnnotationMode` (via a `pendingDrawingProvider` closure or moving `currentDrawing` into
  the view model); keep "Save Drawing" as "commit and start another". **Blast radius:**
  AnnotationOverlayView, WorkspaceViewModel. **Verify:** UI test: draw, tap Done, assert
  annotation persisted. Confidence: High.

### M5. Whole-workspace re-render at 30 Hz: one ObservableObject publishes the clock
- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift:28` (`currentTimeSeconds` @Published on
  the same object as everything else), observed by WorkspaceView, VideoGridView (recomputes
  `LayoutEngine.calculateLayout` per tick, VideoGridView.swift:63-88), PlaybackControlsView,
  TimelineView, AnnotationOverlayView.
- **VERIFIED (structure) / INFERRED (frame cost):** Every 33ms tick invalidates the entire
  workspace tree; with 6 panels + gesture states this is the main suspect for dropped frames on
  older devices. **Change:** move `currentTimeSeconds` (and only it) into a separate
  `PlayheadClock: ObservableObject` (or `@Observable` later) observed only by TimelineView,
  PlaybackControlsView's time label, and the annotation overlay; cache `panelRects` in
  VideoGridView keyed on (videoCount, containerSize, overrides). **Blast radius:** view model +
  4 views, mechanical. **Verify:** Instruments SwiftUI view-body counts before/after.
  Confidence: Medium-High.

### M6. Playhead advances in 30 Hz steps with no interpolation
- **Files:** `WorkspaceViewModel.swift:432` (interval 1/30s), UI-POLISH.md deferred item
  ("Playhead interpolation between time observer ticks (CADisplayLink)").
- **VERIFIED gap vs. own polish doc.** The playhead and "played" fill jump in 33ms quanta; at 2x
  speed that is ~2.5pt jumps on a 380pt timeline -- visible chop. **Change:** CADisplayLink-driven
  display clock that lerps between observer ticks (or implement the C5 master clock with
  CADisplayLink and make the observer merely a correction source). **Blast radius:**
  WorkspaceViewModel + TimelineView. **Verify:** visual; slow-mo screen recording.
  Confidence: Medium (device-visible severity unconfirmed).

### M7. PKDrawing decoded and rasterized on every overlay body evaluation
- **Files:** `Coreo/Annotations/AnnotationOverlayView.swift:282-292` (`try? PKDrawing(data:)` +
  `pkDrawing.image(from:scale:2.0)` inside `@ViewBuilder` per render), PERFORMANCE.md deferred
  ("PencilKit annotation re-renders every frame").
- **VERIFIED:** In annotation mode every state change (and after C2, every 30 Hz tick during
  playback) re-decodes and re-rasterizes each visible drawing -- an allocation + CG render storm.
  **Change:** cache `UIImage` per annotation id (content-hash invalidation; cf. the
  content-hash-cache pattern), rasterize once at commit time, store alongside the annotation in
  memory. MUST land with C2. **Blast radius:** AnnotationOverlayView + small cache type.
  **Verify:** Instruments allocations during playback with 5 drawings. Confidence: High.

### M8. Import thumbnails re-decode JPEG on every SwiftUI redraw
- **Files:** `Coreo/Import/VideoThumbnailView.swift:50-66` (`UIImage(data:)` in body),
  PERFORMANCE.md High-deferred item.
- **VERIFIED:** Horizontal scroll + any state change re-decompresses each thumbnail. **Change:**
  decode once into `@State private var image: UIImage?` in `.onAppear`/`task` (or make
  `VideoAsset.thumbnailData` carry a decoded image via a cache keyed by asset id).
  **Blast radius:** VideoThumbnailView. **Verify:** scroll smoothness; Instruments.
  Confidence: High.

### M9. Remove-thumbnail "44pt hit target" is fake -- frame applied outside the Button
- **Files:** `Coreo/Import/VideoThumbnailView.swift:70-86`: `Button{...}.buttonStyle(...)
  .frame(width:44,height:44).contentShape(Rectangle())` -- the 44pt frame/contentShape wrap the
  button but the tappable region is still the 20pt label inside. Compare the correct pattern in
  WorkspaceView.swift:119-124 (frame+contentShape INSIDE the label).
- **VERIFIED (SwiftUI hit-testing semantics):** UI-POLISH.md's "Remove thumbnail 20x20 -> 44x44"
  claim does not hold. **Change:** move `.frame(width:44,height:44).contentShape(Rectangle())`
  inside the Button's label (keep the visual 20pt circle centered). Also the `.offset(x:12,y:-12)`
  pushes half the hit area outside the ZStack top-right -- re-check clipping. **Verify:** XCUITest
  tap at the corner 18pt from the visual center. Confidence: Medium-High (worth a quick device
  check, SwiftUI hit-testing has version quirks).

### M10. AnnotationToolbar misses promised haptics and HIG hit targets
- **Files:** `Coreo/Annotations/AnnotationToolbar.swift:101-118` (tool buttons ~36x34pt total, no
  haptic; UI-POLISH.md claims "Tool selection -> tick"), `:196-207` (Done ~ 60x23pt; UI-POLISH
  claims Done >= 44pt and a light haptic), `:133-156` (color swatch 24pt).
- **VERIFIED:** Three concrete divergences from UI-POLISH.md's claimed state. **Change:** add
  `Haptic.tick()` to tool selection, `Haptic.light()` to Done; give each toolbar item
  `.frame(minWidth:44, minHeight:44).contentShape(Rectangle())` inside the label. **Blast
  radius:** one file. **Verify:** visual + grep audit against UI-POLISH map. Confidence: High.

### M11. >6 videos renders an all-black workspace (LayoutEngine returns [])
- **Files:** `Coreo/Models/LayoutEngine.swift:29` (`guard videoCount <= 6 else { return [] }`),
  `Coreo/Workspace/VideoGridView.swift:28-31` (`index < rects.count` -> renders nothing),
  `ImportView.swift:48-53` (photosPicker caps a single pick at 6, but repeated picks/Files
  imports stack beyond 6 with no warning -- DESIGN says warn, don't block).
- **VERIFIED:** 7 imports -> sync runs -> workspace shows controls over a black void. **Change:**
  warn at import when count > 6 ("Best results with 2-6 videos") and either hard-cap or make
  LayoutEngine fall back to a 3-column wrap for 7+. **Verify:** unit test LayoutEngine(7) returns
  non-empty OR import cap enforced. Confidence: High.

### M12. Speed picker `.popover` will present as a half-screen sheet on iPhone (iOS 16.0-16.3)
- **Files:** `Coreo/Workspace/PlaybackControlsView.swift:84-88` (popover, 260x52 content),
  project.yml deployment target iOS 16.0.
- **VERIFIED API surface / INFERRED presentation:** Without `.presentationCompactAdaptation(
  .popover)` (16.4+), iPhone shows a full sheet for a one-row picker -- jarring for the most
  frequently used control during practice. **Change:** if 16.4+ available use
  compactAdaptation(.popover); otherwise replace with an inline expanding row of rate chips above
  the control bar (also faster: one tap fewer). Cycle-tap on the speed label
  (`cyclePlaybackRate` exists at WorkspaceViewModel.swift:160-168 but is dead code) with
  long-press for the picker would be the most practice-friendly. **Verify:** device.
  Confidence: Medium-High.

### M13. Time display wrong when timelineStart < 0 (negative sync offsets)
- **Files:** `Coreo/Workspace/PlaybackControlsView.swift:36-44`
  (`formatShort(currentTimeSeconds)` clamps negatives to 0:00 -- shows 0:00 for the whole
  pre-roll), `TimelineView.swift:245-257` (left label same; right label `format(timelineEnd)`
  while the displayed bar spans `timelineDuration`).
- **VERIFIED:** Display should be elapsed-from-start: `currentTimeSeconds - timelineStart` over
  `timelineDuration`. **Blast radius:** two views. **Verify:** unit test with offsets [-2, 0].
  Confidence: High.

### M14. No audio-interruption handling -- play button lies after a phone call / Siri
- **Files:** `WorkspaceViewModel.swift:476-505` (only background/foreground observed; no
  `AVAudioSession.interruptionNotification`).
- **VERIFIED gap:** Interruption pauses AVPlayers at the system level; `isPlaying` stays true,
  pause icon shows while video is frozen, and the time observer stops ticking (same stale-state
  family as C3). **Change:** observe interruption began -> set paused state; ended (+
  `.shouldResume`) -> resume via existing `playAll`. **Verify:** device (set a timer to fire).
  Confidence: High.

### M15. Pinch-zoom pan is unclamped; zoom ignores DESIGN's crop interaction
- **Files:** `Coreo/Workspace/VideoPanelView.swift:116-130` (pan offset unbounded -- content can
  be dragged fully off-panel with no rubber-band and no way to know where it went), DESIGN.md
  ("pinch ... disables auto-crop for that panel").
- **VERIFIED (clamping) / Low add-on (crop semantics):** **Change:** clamp `panOffset` so the
  scaled content always covers the panel (max offset = panelSize*(scale-1)/2), rubber-band past
  it; on zoom > 1 either clear `cropOverrides[index]` per DESIGN or document zoom-on-crop as
  intended. Persist zoom/pan per panel in the project if it should survive the session
  (currently @State -- lost on re-entry; DESIGN says overrides persist). **Verify:** unit test
  the clamp math. Confidence: High.

### M16. Audio source indicator: generic "Audio" label, raw filenames, no confidence surfaced
- **Files:** `Coreo/Workspace/WorkspaceView.swift:234-259` (label is just speaker+"Audio";
  DESIGN: "Audio: [filename]"), menu rows show `lastPathComponent` -- photo-library imports are
  named `UUID-filename` by VideoTransferable (ImportView.swift:368-372), so menu items and
  thumbnails read like `7D2F...-IMG_2041.mov`.
- **VERIFIED:** **Change:** show the selected source's display name in the label (truncated
  middle); strip the UUID prefix when displaying (store a `displayName` on VideoAsset at import);
  consider "Angle 1/2/3" naming with the coverage-bar color as a swatch -- ties the menu to the
  timeline colors. Add `Haptic.tick()` on source switch. **Verify:** visual. Confidence: High.

### M17. "Trim to overlap" missing; trim model fields are render-only
- **Files:** DESIGN.md timeline spec; `CoreoProject.swift:48-52` + `overlapStart/EndSeconds`
  computed (:130-144); TimelineView trimOverlay renders it (:263-304); EDGE-CASES.md notes export
  ignores it; grep: `timelineTrimStartSeconds` never written.
- **VERIFIED:** One-tap feature whose plumbing is 80% built. **Change:** add a "Trim to overlap"
  button in the edit panel that sets the two fields from `overlapStartSeconds/overlapEndSeconds`
  (toggle to clear = the documented undo); clamp seeks/loop to the trim range during playback.
  Export application is the export lens's companion item. **Verify:** unit: fields set; loop
  respects range. Confidence: High.

### M18. statusBarHidden tied to isPlaying causes chrome flicker every play/pause
- **Files:** `Coreo/Workspace/WorkspaceView.swift:75`.
- **VERIFIED toggle / INFERRED visual impact:** Status bar show/hide animates on every
  play/pause; on non-notch devices it shifts the safe area (top bar jumps). Toggling this with
  the most-used button in the app is churn. **Change:** hide only after ~3s of uninterrupted
  playback with no interaction (idle timer), or don't hide at all. **Verify:** device.
  Confidence: Medium.

### M19. Workspace entry shows black panels with no readiness state
- **Files:** `WorkspaceViewModel.swift:399-422` (players created + seeked in init; no
  `.readyToPlay`/`isPlaybackLikelyToKeepUp` observation), VideoPanelView (no placeholder while
  the first frame decodes).
- **VERIFIED gap / INFERRED duration:** For 4-6 HD assets the first frames take a beat; the
  user lands on black tiles. **Change:** show each video's existing `thumbnailData` (already in
  the model!) as a panel placeholder, crossfade to live video when the item reports
  `.readyToPlay`. Cheap and makes entry feel instant. **Verify:** device; slow-disk simulation.
  Confidence: Medium-High.

### M20. Speed segments: no feedback when a segment is added, and the mini-timeline duplicates the main timeline's geometry bugs
- **Files:** `Coreo/Speed/SpeedControlView.swift:371-402` (add segment: no haptic, no animated
  confirmation; picker just vanishes), `:109-145` (mini timeline has correct width math but
  duplicated converters -- third copy of xPosition/seconds in the codebase).
- **VERIFIED:** **Change:** `Haptic.tick()` + brief highlight pulse of the new overlay on add;
  extract a shared `TimelineGeometry` helper (one converter used by TimelineView,
  SpeedControlView, AnnotationMarkerView, HoldMarkerView, AnnotationTimeRangeControl) -- this is
  also the structural fix for H7. Hold markers (pause icons) should also appear on the MAIN
  timeline per DESIGN (currently only in SpeedControlView's strip; TimelineView shows a 1-2pt
  red sliver at :171-183 that is nearly invisible for a 0.01s hold). **Verify:** unit tests on
  shared geometry. Confidence: High.

### M21. Text annotations: fixed 16pt size, no edit-after-create, no delete affordance on selection
- **Files:** `WorkspaceViewModel.swift:230-251` (fontSize hard-coded 16), DESIGN.md ("Adjustable
  font size", "Double-tap text annotation to edit", "Selected annotation shows ... delete
  button"); `TextAnnotationView.swift` supports select+drag only.
- **VERIFIED:** **Change:** double-tap -> re-open the Add Text alert pre-filled; selection shows
  a small floating chip (delete + size +/-). Dancer use case is "DON'T DROP YOUR FRAME" in big
  letters -- size matters. **Verify:** UI test. Confidence: High.

---

## LOW

### L1. Accessibility labels missing on nearly all icon-only buttons
- **Files:** WorkspaceView.swift:112-170 (back/edit/export), PlaybackControlsView.swift:49-61
  (play/pause -- also should use `.accessibilityValue` for state), ImportView.swift:182-199 (+ menu),
  VideoThumbnailView.swift:70-86 (remove), TimelineView (entire scrub bar has no
  `.accessibilityAdjustableAction`), ExportProgressView (progress not announced).
  AnnotationToolbar is the only surface with labels (VERIFIED).
- **Change:** `.accessibilityLabel` on every icon button; make the timeline an adjustable element
  (increment/decrement = +/-1s seek); `.accessibilityValue("\(Int(progress*100)) percent")` on
  the export ring. UI-POLISH.md already lists this as deferred. Confidence: High.

### L2. Dynamic Type ignored everywhere
- Fixed `.system(size: 9...17)` fonts across TimelineView (9pt labels), SpeedControlView,
  AnnotationToolbar, ExportProgressView (VERIFIED). Use text styles
  (`.caption2.monospacedDigit()` etc.) or `@ScaledMetric`; verify the 80pt timeline grows
  gracefully or pin chrome fonts deliberately (decide and document). Confidence: Medium.

### L3. Reduce Motion not respected
- No `accessibilityReduceMotion` checks (VERIFIED grep). Springs/pulses are mild; gate the
  panel-zoom snap and toolbar transitions when set. Confidence: High, impact low.

### L4. `cyclePlaybackRate` dead code; double-tap speed affordance unwired
- `WorkspaceViewModel.swift:160-168` unused (VERIFIED). Either remove or wire as tap-to-cycle on
  the speed chip (see M12). Confidence: High.

### L5. exitAnnotationMode doesn't resume playback (DESIGN says Done resumes)
- `WorkspaceViewModel.swift:203-207` deliberately doesn't resume; DESIGN.md says resume.
  Track `wasPlayingBeforeAnnotation` and restore it on Done (VERIFIED divergence). Confidence: High.

### L6. Eraser: full-canvas drawings erased by tapping anywhere; topmost-only
- `AnnotationOverlayView.swift:232-241` (VERIFIED). Acceptable v1, but show which annotation will
  be deleted (brief red outline on the candidate) before committing, or require tap on the
  drawing's stroke bounds (`PKDrawing.bounds` is available). Confidence: Medium.

### L7. Document-picker imports run serially; photo imports complete in nondeterministic order
- `ImportView.swift:58-66` (serial `for ... await`), `:339-354` (parallel Tasks append in
  completion order, so the thumbnail row order != selection order) (VERIFIED). Import in parallel
  with `withTaskGroup` and insert results by original index. Confidence: High.

### L8. `ExportEngine.export` is @MainActor -- composition assembly runs on the main thread
- `ExportEngine.swift:50-55` (VERIFIED annotation): `insertTimeRange`/`scaleTimeRange` over 6
  tracks is synchronous CPU work on main during the "Preparing..." phase; brief UI hitch at
  export start. Drop @MainActor on `export`/`performExport` (only `progressHandler` needs main --
  it's already called from a MainActor task) and hop to main for UIApplication background-task
  calls. Confidence: Medium-High.

### L9. No "Add at least 2 videos to sync" hint; thumbnail add/remove unanimated
- ImportView populated state with 1 video shows nothing actionable (VERIFIED); DESIGN specifies
  the hint. Add caption under the row + `withAnimation` on `videos` mutations
  (`removeVideo`/append currently jump). Confidence: High.

### L10. Export share is one-shot -- file deleted on sheet dismissal
- `WorkspaceView.swift:89-95` + `cleanUpExportedFile` (VERIFIED). If the user dismisses the share
  sheet (very easy accidentally), the export is gone; re-export takes a minute. Keep the last
  export until the next export or workspace exit; add a small "Share again" affordance.
  Confidence: Medium.

### L11. Sync spinner replaces the CTA area but thumbnails stay removable mid-sync
- Covered functionally in H3(3); UI side: dim/disable the thumbnail row while `isSyncing`
  (VERIFIED gap). Confidence: High.

---

## Taste-based feature proposals (dancer-first affordances; all absent from code, most absent from DESIGN)

These have license per the survey scope; ordered by value-for-effort.

1. **Frame step buttons** (prev/next frame chevrons flanking play, or tap-left/right zones while
   paused). AVPlayerItem `step(byCount:)` steps all players; dancers live frame-by-frame on
   tricky counts. Tiny implementation, huge value.
2. **A-B loop**: long-press timeline (or two playhead flags) to define a practice loop; loop the
   segment instead of the full timeline; persists as part of the project. The #1 practice-tool
   feature in every dance app review.
3. **Count-in**: optional 3-2-1 beep/flash before playback resumes (toggle in edit panel) so the
   dancer can get into position after tapping play. Pairs with a "tap-anywhere-to-play" mode for
   sweaty one-handed use.
4. **Mirror mode**: per-panel horizontal flip (scaleEffect(x: -1) on the panel + flipped export
   transform). Dancers learning from a facing-camera video constantly mentally mirror; this is a
   one-line transform with outsized differentiation.
5. **Tap panel to solo/fullscreen**: single tap zooms a panel to full grid (others shrink to a
   filmstrip), tap again to restore. Faster than pinch for "let me watch the back angle".
6. **Scrub snapping + haptic ticks**: while dragging the playhead, magnetize to annotation starts,
   hold points, and segment boundaries (`Haptic.tick()` on each snap; escape velocity on fast
   drags). Infrastructure exists (markers, segments).
7. **Fine-scrub modifier**: drag finger vertically away from the timeline to reduce scrub ratio
   (the classic iOS video-scrubber pattern) -- critical for picking exact frames on a 5-min
   timeline 380pt wide.
8. **Per-angle audio preview**: tapping an entry in the audio menu while playing should switch
   live (it does -- `setAudioSource` is immediate, VERIFIED) -- surface that by keeping the menu
   open or using an inline selector so users can A/B audio quality quickly.
9. **Sync confidence badge**: small colored dot per video (green/yellow) in the workspace (e.g.,
   on coverage bars) using `SyncResult.confidence`, tappable -> opens the H10 nudge UI.

---

## For JMT (judgments that need the running app on a device)

- Scrub latency feel after H6: whether tolerance-based drag scrubbing is enough on 4-6 panels or
  whether single-panel-live scrubbing is needed (iPhone 12-class hardware is the floor).
- Whether the 30 Hz playhead (M6) reads as choppy in person, and whether CADisplayLink
  interpolation is worth the battery cost during long practice sessions.
- The speed `.popover` presentation on each supported iOS version (M12), and whether the inline
  chip row feels better than the popover at all.
- statusBarHidden flicker (M18) on notch vs non-notch devices.
- Marker-tap vs scrub-drag gesture arbitration in practice (M2) -- SwiftUI's child-gesture
  precedence with `minimumDistance: 0` parents is empirically version-dependent.
- Haptic intensity choices (light vs medium for play/pause during a sweaty practice session --
  consider raising to medium since the phone is often on the floor/propped).
- Whether forced portrait on iPhone (project.yml) should be revisited: a 2-angle landscape
  project in portrait yields two tiny letterboxed panels stacked by LayoutEngine's [2] config
  side-by-side; landscape workspace support is plausibly the single biggest viewing-area win.
- Real black-panel duration on workspace entry (M19) on slow storage / iCloud-offloaded videos.

---

## TOP 10 (one-liners, priority order)

1. **C1** Wire annotation-mode entry from the toolbar -- annotation creation is currently impossible.
2. **C2** Mount AnnotationOverlayView during normal playback (with M7 raster cache) -- notes never show.
3. **C3** Add hold-resume scheduling -- a live Hold freezes the app forever.
4. **C5+H8** Replace reference-anchored clock with an independent master clock + drift re-lock; fixes unplayable head/tail, early loop, and inter-panel drift.
5. **C4+H3** Restore an explicit Sync/Continue button, phase-labeled determinate sync progress with cancel; back navigation is a dead end today.
6. **H1** Wire `project.save()`/`load()` -- all user work is silently discarded.
7. **H4** Stop claiming "Adding annotations..." during export and warn that annotations are excluded (until PanelCompositor renders them).
8. **H5** Make Cancel actually cancel the AVAssetExportSession.
9. **H6+H7** Tolerance-based coalesced scrubbing + one shared timeline coordinate helper (playhead currently misaligned up to 16pt and seek-storms 6 players).
10. **H9** Lazy audio-session activation so opening the app stops killing the dancer's music.
