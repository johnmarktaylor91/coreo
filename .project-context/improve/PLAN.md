# Coreo Full-Scope Improvement -- Synthesis Plan

Source: 6 Fable survey reports in `.project-context/improve/reports/` (2026-06-11).
~190 findings total. This plan dedupes, pins design decisions, and partitions the
work into 6 SEQUENTIAL Codex implementation specs (one branch, one codex at a time,
disjoint-enough write targets, each wave sees the previous wave's changes).

## Cross-lens consensus (found independently by 3+ agents)

1. **Persistence is dead code.** `CoreoProject.save()/load()` never called; absolute
   tmp URLs persisted; parallel index-coupled arrays. All work lost on app kill.
2. **Annotations are invisible everywhere.** Creation unreachable (toolbar sets
   `selectedTool` but only marker-tap sets `isAnnotationMode`); overlay mounts only
   in annotation mode (which pauses playback); export explicitly skips annotations
   (403-line AnnotationCompositor is dead code with 5-axis geometry bugs).
3. **Holds broken 3 ways.** Live: pause stops the time observer that would resume ->
   permanent freeze; 0.01s window vs 33ms polling means usually no-op. Export:
   `insertEmptyTimeRange` -> black gap, not freeze.
4. **Export diverges from preview.** cropRect declared/passed/never read; preview
   FITs vs export FILLs; layout variant can structurally differ; cancel is fake
   (session keeps encoding, share sheet pops after cancel); bumper temp file deleted
   before session reads it; annotations absent.
5. **6-video layout bug.** LayoutEngine includes 5-panel candidates for count 6 ->
   6th video dropped in preview, full-frame overlay in export. >6 -> blank workspace
   (imports uncapped).
6. **One audio-less video aborts entire sync** (throwing task group; the filter
   EDGE-CASES.md claims exists doesn't).
7. **Sync memory blowup.** Full-length FFT (2^23 for 5-min clips) x unbounded
   concurrent correlations -> multi-GB peak, jetsam risk.
8. **Reference-player clock is wrong.** Loop fires at reference end (reference chosen
   by bitrate, not length) -> truncated tails; late-starting videos seeked to 0 and
   played hidden -> permanently desynced when revealed; zero drift correction.
9. **Doc-code drift.** 6+ fixes documented as DONE in EDGE-CASES.md/PERFORMANCE.md
   are absent from code (autoreleasepool, reserveCapacity, single-copy, vDSP_zvmul,
   sync cancellation, no-audio filter). Do not trust docs; trust reports.
10. **30 Hz whole-workspace invalidation** (monolithic ObservableObject playhead) +
    PKDrawing decode/rasterize per body evaluation.

## Pinned design decisions (architect calls -- specs MUST follow)

- **D1 FFT convention:** the IMPLEMENTATION's sign convention is canonical and
  correct end-to-end. Fix the inverted doc comment and the 2 inverted AudioSyncTests
  to match the implementation. NEVER flip the implementation to satisfy the tests.
  Add an end-to-end synthetic-offset test (generate two signals with known offset,
  assert recovered offset) as the convention lock. (concurrency report, finding 3)
- **D2 Hold semantics (single definition):** a hold at timeline time T freezes the
  composed frame for duration D, then playback resumes. Live: timer-driven resume +
  boundary-crossing detection (trigger when playhead CROSSES T, not when a 33ms
  sample lands inside a 0.01s window). Export: freeze via one-frame
  scaleTimeRange (or equivalent retime), never insertEmptyTimeRange.
- **D3 Master clock:** unified timeline driven by a host-time-anchored master clock
  independent of any player. Timeline end = max(clip timeline end); loop there.
  Players are activated only inside their [start, end) windows: outside -> paused +
  hidden; on entry -> pre-seeked, started via setRate(_:time:atHostTime:). Periodic
  drift check (~1s) resyncs players beyond ~1 frame of error.
- **D4 WYSIWYG:** preview semantics are the spec. Export uses the same LayoutEngine
  algorithm, aspect-FIT (letterbox) like preview, proportionally-scaled gap, and
  applies cropRect in BOTH preview (geometrically correct) and export.
- **D5 Data model:** replace index-coupled parallel arrays with per-video fields on
  VideoAsset (syncOffset, cropRect, cropOverride, trim, canvasSize...) keyed by UUID.
  Add schemaVersion. Project store: Application Support/Projects/<uuid>/ with
  project.json (atomic write) + media files COPIED into the project dir at import.
  Debounced autosave on mutation + save on background; load on launch.
- **D6 Deployment target:** raise iOS 16.0 -> 17.0 (unlocks @Observable for the
  30 Hz invalidation fix). Flagged to JMT in TABLED.md; reversible.
- **D7 Audio session:** configure category at launch but activate only on first
  play (stop killing the dancer's background music). Handle interruptions (call/
  Siri -> pause + correct UI state) and route changes.
- **D8 Video cap:** enforce 2-6 at both pickers with clear messaging. LayoutEngine
  must return a valid layout for ANY count 1-6 (fix the 6-video candidate bug:
  no 5-panel candidates for count 6).
- **D9 Export audio:** reference angle's audio, silent-track fallback if none.
  Per-angle audio selection UI = Wave 6 taste item.
- **D10 TimeMapper:** single source of truth for timeline<->clip<->export time
  mapping lives in Models/ (created Wave 3, adopted by playback/annotations/export
  in Waves 4-5; Wave 2's export fixes may keep local math, unified later).

## Implementation waves (sequential, branch codex/full-scope-improvements)

- **Wave 1 -- sync-and-import** (Coreo/Sync/**, Coreo/Import/**, sync tests):
  no-audio tolerance (engine skips audio-less clips, returns partial results +
  per-clip status; ImportViewModel surfaces which clips couldn't sync), correlation
  concurrency cap (2), shared FFT setup, windowed/downsampled correlation (target
  <150MB peak), fix FFT numerics (packed-spectrum DC/Nyquist handling, inverse
  scaling 2x -> confidence calibration), vDSP_zvmul for the scalar complex-multiply
  loop, AudioExtractor autoreleasepool + single-copy + reserveCapacity, real
  cancellation (checkCancellation in loops, cancellable from UI), D1 test fixes +
  end-to-end convention-lock test, import-in-progress UI, iCloud/error surfacing
  (no swallowed try?), 2-6 cap enforcement (D8 UI side), determinate sync progress
  with correct phase labels + cancel, haptics on sync success/failure.
- **Wave 2 -- export-core** (Coreo/Export/** only; annotations excluded):
  holds as freeze frames (D2), apply cropRect in compositor (D4), aspect-FIT (D4),
  layout parity incl. scaled gap (D4), real cancellation (checkCancellation +
  cancelExport + temp cleanup + block concurrent exports), bumper temp-file
  lifecycle fix (deleted-before-read), insertTimeRange from actual track timeRanges,
  honor trim if model has it (it will after Wave 3 -- keep seam), D9 audio fallback,
  disk-space preflight proportional to estimated output, accurate progress, fix
  sanitizeIndices silently zeroing sync offsets, export-time annotation hook left
  as a clean seam for Wave 5.
- **Wave 3 -- models-and-persistence** (Coreo/Models/**, Coreo/App/**, project.yml,
  call-site ripple everywhere): D5 data model reshape + migration-free cutover
  (nothing shipped), D6 target raise to iOS 17, LayoutEngine 6-video fix + 1-6
  guarantee (D8), TimeMapper created (D10), persistence wiring (autosave/load,
  media copied into project dir, missing-media recovery UI hook), schema version.
- **Wave 4 -- playback-core** (Coreo/Workspace/**, Coreo/Speed/**): D3 master clock
  + activation windows + drift correction, loop at unified end, seek coalescing
  (zero-tolerance only for frame-step), atomic rate changes incl. speed segments,
  D2 live holds, D7 audio session + interruption handling, back-navigation dead-end
  fix + re-sync entry point, manual sync nudge UI (recovery path for bad
  correlation), 30 Hz invalidation fix via @Observable split (PlaybackController /
  AnnotationStore / ExportCoordinator split of WorkspaceViewModel), PKDrawing
  rasterize-once cache, trim plumbed to playback.
- **Wave 5 -- annotations-end-to-end** (Coreo/Annotations/**, WorkspaceView mount,
  Export/AnnotationCompositor + PanelCompositor hook): creation reachability fix,
  always-mounted read overlay with fades during playback, wire
  AnnotationTimeRangeControl ("Show always" + ranges), store authoring canvas size
  in model, ONE shared rasterizer for preview + export (identical fonts, strokes,
  arrowheads, fade curves), correct coordinate-space conversion (screen->video,
  per-cell, mixed resolutions), annotations rendered in-compositor (CIImage),
  fades honor TimeMapper (speed/holds; no bumper bleed).
- **Wave 6 -- tests-quality-taste** (CoreoTests/**, configs, cross-cutting polish):
  unit tests per the architecture report's 13-step plan (SpeedMap, timeline math,
  LayoutEngine incl. 6-video regression, TimeMapper, ExportPlan, sync orchestration),
  make Tier-1 selector real (UnitTests suite exists and runs), .swiftlint.yml +
  .swiftformat configs + violations fixed, dead-code removal (~700 lines), dedupe
  (timeline math x5, hex parsing x3, arrowhead geometry x3), accessibility pass
  (labels, 44pt targets incl. the fake remove-button target, VoiceOver on timeline,
  reduced motion), haptics per UI-POLISH.md claims, taste features: frame-step
  buttons, mirror mode, per-angle audio mute.

## Verification per wave

Gates: `xcodebuild build` + full `xcodebuild test` (destination iPhone 17 Pro,
iOS 26.3 sim). Baseline-red tests recorded in baseline-tests.md -- do not regress
baseline-green; fixing baseline-red in your territory is in scope. Fallback compile
gate if xcodebuild breaks again: `xcrun -sdk iphonesimulator swiftc -typecheck
-target arm64-apple-ios17.0-simulator -parse-as-library $(find Coreo -name '*.swift')`.
swiftlint/swiftformat gates activate in Wave 6 once configs exist.
