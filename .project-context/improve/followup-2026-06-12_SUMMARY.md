# Coreo Follow-Up Run -- Summary (2026-06-12)

JMT directive: "dispatch a followup for all work that doesnt require my own
manual testing." 5 sequential Codex waves on `codex/followup-improvements`,
each independently gate-verified, ff-merged to main (c7c7a82 -> e234bec).
Net +2,899/-426 across 45 files. Zero persisted-schema changes by design --
nothing in this run needed JMT signoff.

## Quality gates at merge
- Full suite: 140 tests, 0 failures (was 116 at run start; +24)
- Swift 6 language mode + SWIFT_STRICT_CONCURRENCY=complete, concurrency
  diagnostic sweep SILENT (closes the PanelCompositor sendability residual)
- swiftlint: 0 errors (23 accepted FFT force-unwrap warnings unchanged)
- swiftformat --lint: clean
- Attribution: human-only authorship, verified
- Hygiene: F1-F4 touched no .md; F5 touched ONLY the three target docs

## What changed (by wave)
1. **F1 -- playback features** (422e9c1): count-in 3-2-1 (UserDefaults
   toggle, cancellable, Reduce Motion aware, never fires on programmatic/
   hold/loop resumes); A-B loop (session-only, crossing-detection seek via
   coalesced path, swap/reject rules, clear-on-duration-shrink, timeline
   band); scrub snapping (annotation starts / holds / segment boundaries /
   ends, point-radius via coordinate mapper, engage/release + single
   haptic, never on frame-step or programmatic seeks). +9 tests.
2. **F2 -- nudge/mirror/re-pick** (f86371d): waveform sync nudge view
   (stacked RMS envelope strips, drag-to-nudge + frame buttons, Reset to
   auto-sync, no-audio placeholder, off-main cached envelopes; D1 sign
   convention asserted in tests); export mirror toggle (visible only when
   a panel is mirrored, default OFF = old behavior, flip applied post-crop
   in PanelCompositor, annotations stay canvas-space to match preview);
   missing-media re-pick (reuses import picker + media-copy, UUID
   preserved so offsets/annotations/crop survive, 0.25s duration tolerance
   warning, never blocks). +7 tests.
3. **F3 -- Swift 6** (2e725d7): SWIFT_VERSION 6.0 + strict complete in
   project.yml; @MainActor Haptic; @unchecked Sendable ONLY with real
   synchronization (EndBumperCache/BackgroundState/ExportSessionBox/
   ProjectStore via NSLock; PanelCompositor serialized on its render
   queue); task-local FFT plans (no shared FFTSetup across child tasks);
   notification/task captures fixed. Behavior-equivalent by design.
4. **F4 -- snapshot layer** (899d046): swift-snapshot-testing 1.19.2,
   test target ONLY. 8 snapshot tests: rasterizer images (drawing, text,
   arrow, composition, mid-fade vs full, wide vs portrait letterbox
   geometry -- the preview/export parity lock) + LayoutEngine text dumps
   (1-6 mixed aspects, degenerates). Valid only on iPhone 17 Pro OS=26.5
   (documented in file headers). Stability proven across 3 consecutive
   full runs. XCUITest stretch deliberately skipped (anti-flake).
5. **F5 -- docs rewrite** (e234bec): EDGE-CASES.md, PERFORMANCE.md,
   UI-POLISH.md rewritten 100% from current code with file refs; ~15
   stale falsehoods killed (e.g. "no schema versioning", "remove-only
   recovery", "no drift correction", "44pt everywhere"). These docs are
   TRUSTWORTHY again as of e234bec.

## Found while documenting (small follow-up queue, NOT fixed this run)
- Compact panel nudge buttons are 28x24 (<44pt) and lack explicit
  accessibility labels -- contradicts the wave-6 a11y bar. Best next fix.
- Silent/quiet audio has no RMS pre-filter (only low sync confidence).
- Export omits the audio track entirely when every source lacks audio
  (no silent-track synthesis).
- Force-quit inside the 2s autosave debounce window can lose last edit.
- Unused design tokens: CoreoAnimation.press, CornerRadius.card.

## Needs JMT (unchanged from sprint, now with new material)
On-device per MANUAL-TESTING.md; each wave's log carries a device-test
checklist (/tmp/coreo_f1.log, _f2.log). New headline checks: waveform
nudge drag feel + sign direction, export-mirror WYSIWYG vs preview,
re-pick recovery, count-in/loop/snapping feel. Reversible calls this run:
export-mirror default OFF; A-B loop session-only (not persisted);
XCUITest smoke skipped.
