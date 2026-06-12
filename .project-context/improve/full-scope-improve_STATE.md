# full-scope-improve STATE

round: 1
phase: 3-implementation (wave 1 pending infra)
baseline_commit: f23d5fa (main); test-compile fix 9537ec3
test_baseline: BLOCKED -> iOS 26.5 simulator platform downloading (/tmp/coreo_platform_download.log).
  Earlier: test target didn't compile (ModelTests.swift:256, fixed in 9537ec3). Full
  suite results still pending; Wave 1 codex records its own baseline as first action.
branch_plan: codex/full-scope-improvements off main; merge to main when green; delete branch
synthesis: PLAN.md (6 waves, pinned decisions D1-D10) + TABLED.md written 19:27
wave1_spec: /tmp/PROMPT_coreo_wave1_sync_import.md (written, NOT yet dispatched --
  waiting for xcodebuild gates to work: platform download then verify -showdestinations)

## Case routing (read FIRST every wake-up; check git log -3, pgrep, log sizes)

- A: codex done + committed -> verify gates, dispatch next wave
- B: codex still running -> ack, yield turn
- C: codex quota/fail -> fallback chain (sonnet mechanical / opus gnarly subagent), log it
- D: tests failed -> diagnose root cause, one fixup spec, max 3 rounds per issue

## Stop criteria (quantitative)

- All synthesized specs landed+verified OR 3-strike residual documented
- Tier 3 gates green on main (or no worse than baseline-red, documented)
- SUMMARY.md + TABLED.md written; iMessage sent via send-to-jmt.sh

## Authorization

- JMT 2026-06-11 18:16 EDT: FULL SCOPE, fables for survey (explicit override),
  FULL OVERRIDE on data-model + sync-algorithm guardrails, merge to main when green.
- Tabled only: on-device aesthetics, App Store/signing/provisioning, StoreKit/IAP.

## Specs (fill in Phase 2)

(pending synthesis)

## Iteration log

- 19:50: Baseline recorded: 76 tests / 5 failures, all survey-predicted (see
  baseline-tests.md). iOS 26.5 platform installed after download. Wave 1 codex
  dispatched pid=62499 log=/tmp/coreo_wave1.log, watcher armed (Monitor bpsim52ws).
  phase: wave-1-running
- 20:35: Wave 1 DONE commit 2d59156 (6 files, +1026/-141). Verified independently:
  81 tests / 3 failures = known LayoutEngine trio only. AudioSync convention locked
  by e2e test. Wave 2 (export-core) dispatched pid=68969 log=/tmp/coreo_wave2.log,
  spec /tmp/PROMPT_coreo_wave2_export_core.md. phase: wave-2-running
- 21:05: Wave 2 DONE commit 4741b84 (7 files, +1044/-271; ExportPlan + 8 tests).
  Verified independently: 89 tests / 3 known LayoutEngine reds. Wave 3
  (models-and-persistence) dispatched pid=76634 log=/tmp/coreo_wave3.log, spec
  /tmp/PROMPT_coreo_wave3_models_persistence.md. Expect ZERO reds after this wave.
  phase: wave-3-running
- 21:55: Wave 3 DONE commit d064fa1 (22 files, +1396/-442; ProjectStore, TimeMapper,
  model reshape, LayoutEngine fix, iOS 17 via xcodegen). Verified independently:
  98 tests / 0 failures -- SUITE FULLY GREEN. Wave 4 (playback-core) dispatched
  pid=89345 log=/tmp/coreo_wave4.log, spec /tmp/PROMPT_coreo_wave4_playback_core.md.
  phase: wave-4-running
- 22:40: Wave 4 DONE commit 7cf9807 (11 files, +1023/-202; master clock, activation
  windows, holds, audio session, nudges, timeline geometry; 104/0 verified). Declared
  incomplete: @Observable split + LayoutEngine caching -> one-retry fixup Wave 4b
  dispatched pid=97696 log=/tmp/coreo_wave4b.log, spec
  /tmp/PROMPT_coreo_wave4b_observable_split.md. Wave 5 (annotations) AFTER 4b since
  it builds on AnnotationStore. phase: wave-4b-running
- 23:20: Wave 4b DONE commit 01b09c4 (13 files, +1351/-860; PlaybackController/
  AnnotationStore/ExportCoordinator/LayoutCache; no ObservableObject left; playhead
  scoped). Verified 104/0. Wave 5 (annotations) dispatched pid=5278
  log=/tmp/coreo_wave5.log, spec /tmp/PROMPT_coreo_wave5_annotations.md.
  phase: wave-5-running
- 00:05: Wave 5 DONE commit 4c79892 (13 files, +897/-488; AnnotationRasterizer
  shared preview/export, creation reachable, playback overlay + fades, time-range
  editing, dead AnnotationCompositor removed). Verified 113/0. Wave 6 (final:
  lint/format configs+sweep, Crop full-body+batch API+parallel import, a11y,
  frame-step/mirror/per-angle-mute) dispatched pid=11703 log=/tmp/coreo_wave6.log,
  spec /tmp/PROMPT_coreo_wave6_quality_taste.md. phase: wave-6-running
- 00:55: Wave 6 DONE (db0f83f style + 9210e15 feat). Tier 3 gates verified by
  architect: 116/0 tests, swiftlint 0 errors, swiftformat clean, attribution
  clean, no doc touches. FF-merged to main, branch deleted, artifacts committed
  (fe5e000), pushed to origin. SUMMARY.md written. JMT iMessaged. Gate file all
  PASS. phase: DONE

- 2026-06-11 19:01 EDT: Kickoff fired. Preflight clean (no sentinels, 96GB disk).
  Baseline commit f23d5fa. Full-suite test baseline launched in background.
  Dispatching 6 Fable survey agents.
