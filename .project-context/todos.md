# Task & Bug Tracker

## Active Tasks
- [ ] [MED] Fix compact panel nudge buttons: 28x24 (<44pt) and missing explicit
      accessibility labels -- contradicts the wave-6 a11y bar (found 2026-06-12
      during F5 doc verification; best next micro-fix)
- [ ] [MED] Add app icon to Assets.xcassets
- [ ] [LOW] Silent/quiet audio: consider RMS pre-filter before FFT correlation
      (today only surfaces as low sync confidence)
- [ ] [LOW] Export: synthesize silent audio track when every source lacks audio
      (today the output has no audio track at all)
- [ ] [LOW] Autosave: force-quit inside the 2s debounce window can lose the
      latest edit (accepted risk; revisit if JMT hits it in practice)
- [ ] [LOW] Remove or wire unused design tokens: CoreoAnimation.press,
      CornerRadius.card
- [ ] [LOW] Add fastlane setup for build automation

## Awaiting JMT (manual testing per MANUAL-TESTING.md)
- [ ] On-device feel pass + aesthetics (TABLED.md pointers)
- [ ] Annotation preview-vs-export parity eyeball on real footage
- [ ] Full-body crop quality on real dance footage
- [ ] New features: waveform nudge feel/sign direction, export-mirror WYSIWYG,
      re-pick recovery, count-in/loop/snapping feel (checklists in wave logs)

## Bugs
(None known -- suite 140/0 as of e234bec)

## Improvements (Nice-to-Have)
- [ ] Instruments profiling on device (memory with 6 AVPlayers, export thermal)
- [ ] XCUITest golden-path smoke (deliberately skipped in F4 as flake risk;
      revisit with a stable fixture strategy)
- [ ] Deferred deluxe features if JMT wants them: richer per-angle audio mixing,
      export-side mirroring per-panel control, re-pick from Files (photo picker
      only today)

## Completed (recent)
- [x] Follow-up run 2026-06-12: count-in / A-B loop / scrub snapping; waveform
      sync nudge; export mirror toggle; missing-media re-pick; Swift 6 strict
      concurrency (zero diagnostics); snapshot test layer (rasterizer +
      LayoutEngine); EDGE-CASES/PERFORMANCE/UI-POLISH rewritten from code.
      140 tests/0 failures at e234bec.
- [x] Full-scope improvement run 2026-06-11: 6 waves + fixup, 116/0 tests,
      see improve/SUMMARY.md
- [x] swiftlint + swiftformat configs + repo-wide pass (2026-06-11, wave 6)
- [x] Run tests and fix failures (2026-06-11: suite could not compile -> green)
- [x] Export pipeline verified: ExportPlan unit tests + rasterizer snapshot
      parity locks (2026-06-12)
- [x] LayoutEngine result caching (LayoutCache, 2026-06-11 wave 4b)
- [x] Full codebase scaffolding: 36 source files, 5 test files (2026-03-16)
