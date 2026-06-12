# Coreo Full-Scope Improvement Run -- Summary (2026-06-11/12)

Authorized 18:16 EDT, kicked off 19:01, merged to main ~00:50. 8 commits on main
(f23d5fa baseline -> 9210e15), net ~+6,500/-2,700 across ~60 files.

## Process
6 parallel Fable survey agents (~190 findings, reports/ dir) -> synthesis with 10
pinned design decisions (PLAN.md D1-D10) -> 7 sequential Codex implementation
dispatches (6 waves + 1 fixup), each gated on build + full test suite -> architect
review + independent gate verification after every wave -> ff-merge to main.

## Quality gates at merge
- Full suite: 116 tests, 0 failures (was: suite couldn't compile; then 76/5)
- swiftformat --lint: clean (0/60 files)
- swiftlint: 0 errors (23 force-unwrap warnings in FFT pointer code -- idiomatic)
- No regressions at any wave; every wave independently verified

## What changed (by wave)
1. **Sync + import** (2d59156): no-audio clips no longer abort sync (per-clip
   statuses); correlation memory capped (windowed FFT, bounded concurrency,
   shared plan) ~GB -> <150MB; FFT numerics fixed (DC/Nyquist packing, 2x scaling,
   vDSP_zvmul); real cancellation; sign convention locked by e2e test (D1: the
   implementation was right, docs/tests were inverted); import: per-item errors +
   retry, 2-6 cap enforced, parallel imports, determinate cancellable progress,
   haptics.
2. **Export core** (4741b84): holds export as freeze-frames not black gaps; crop
   rects actually applied; aspect-FIT parity with preview; real cancellation (no
   share sheet after cancel); bumper temp-file lifecycle fixed; track-accurate
   insert ranges; loud sync-offset mismatch; audio fallback; estimate-based disk
   preflight; off-main orchestration; source-derived fps; pure ExportPlan + tests.
3. **Models + persistence** (d064fa1): parallel arrays GONE -- per-video state on
   VideoAsset (UUID-keyed); ProjectStore in Application Support with media copies,
   relative paths, atomic writes, schema versioning, autosave (debounce +
   background), load-on-launch with continue/new choice, missing-media recovery;
   LayoutEngine 6-video bug fixed (1-6 guaranteed); TimeMapper = single source of
   truth for time math; deployment target 16 -> 17.
4. **Playback core** (7cf9807 + 01b09c4): host-time master clock (reference-player
   anchor GONE -- tails reachable, late-start clips join in sync); player
   activation windows (PlayerSyncPlan, unit-tested); ~1s drift correction; seek
   coalescing (no more 6-player zero-tolerance seek storms); atomic rate changes;
   live holds actually freeze-and-resume (crossing detection + timer); audio
   session activates on play only (background music survives app open),
   interruption/route handling; back-nav + re-sync always available; per-panel
   manual sync nudge; @Observable split (PlaybackController / AnnotationStore /
   ExportCoordinator / LayoutCache) -- 30 Hz playhead no longer invalidates the
   whole workspace; timeline coordinate transform unified (16pt mismatch fixed).
5. **Annotations** (4c79892): creation reachable from toolbar (was impossible);
   always-on playback overlay with fade envelopes; time-range + show-always
   editing wired; ONE shared rasterizer for preview AND export (fonts, strokes,
   arrowheads, fades identical); coordinate mapping correct across mixed
   resolutions/letterboxing; export visibility warped through TimeMapper (speed/
   holds correct, no bumper bleed); rasterize-once cache; dead 403-line
   AnnotationCompositor deleted.
6. **Quality + taste** (db0f83f + 9210e15): .swiftformat/.swiftlint.yml added,
   repo formatted, 0 lint errors; Vision detects FULL body (feet no longer
   cropped); batch image API replaces deprecated per-frame calls; crop runs
   concurrent with sync at import; preview/export crop parity through shared rect
   math; accessibility (VoiceOver on timeline, labels, real 44pt targets, reduced
   motion); haptics; dancer features: frame-step buttons, per-video mirror mode
   (preview-only), per-panel audio mute (audio-source-only by default).

## Residuals (known, accepted)
- 23 swiftlint force-unwrap warnings (FFT withUnsafeMutableBufferPointer idiom).
- Pre-existing Swift 6 sendability warnings in PanelCompositor (build is Swift 5
  mode; strict-concurrency migration is a possible future wave).
- Mirror mode is preview-only (export mirroring deferred deliberately).
- Missing-media recovery is remove-only (re-pick = future polish).

## Needs JMT (see TABLED.md)
On-device: aesthetics pass, annotation preview-vs-export parity eyeball, full-body
crop quality on real footage, scrub/playback feel, device-test checklists from
waves 4-6 (in their /tmp logs and this dir). Reversible calls I made: iOS 17
target, aspect-FIT export, reference-angle audio default, auto-navigate kept.
