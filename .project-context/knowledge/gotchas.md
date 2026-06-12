# Coreo Gotchas & Edge Cases

<!-- Agents: READ THIS before making changes. Append as you discover things. -->
<!-- Format: - [MODULE] GOTCHA: <description> -->

- [Workspace] @MainActor classes cannot call instance methods from deinit — deinit is nonisolated. Do NOT put tearDown logic in deinit. Use explicit cleanup or rely on ARC deallocation of AVPlayer instances.
- [Annotations] AnnotationCompositor was DELETED (2026-06-11 wave 5). The one shared raster path for preview AND export is `AnnotationRasterizer.image(for:destinationSize:)`; fade opacity comes from `TimedAnnotation.opacity(at:)`. Changing its output invalidates committed snapshot PNGs -- that is intended; they are the parity lock.
- [Build] Xcode 26 simulators are iPhone 17 series, not iPhone 16. Destination: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5` (snapshot tests are ONLY valid on this pinned destination).
- [Build] Deployment target is iOS 17 (raised from 16 on 2026-06-11; unlocks @Observable). Pre-run notes about iOS 16.0 API limits are obsolete.

## From full-scope improve run (2026-06-11)
- `-only-testing:CoreoTests/UnitTests` matches a CLASS named UnitTests, not the
  UnitTests/ directory -- it silently runs zero tests. Run the suite unfiltered.
- After Xcode updates: `sudo xcodebuild -runFirstLaunch` (needs admin) AND the
  matching iOS simulator platform (`xcodebuild -downloadPlatform iOS`, ~8.5GB)
  or destination resolution fails with "Supported platforms ... is empty".
- EDGE-CASES.md / PERFORMANCE.md at repo root described fixes that never existed
  in code (pre-run doc drift). SUPERSEDED 2026-06-12: all three root docs
  (incl. UI-POLISH.md) were rewritten from code with file refs (commit e234bec)
  and are trustworthy again AS OF that commit -- re-verify after major changes.
- FFT sign convention (D1, locked by engine e2e test): clipLocalTime =
  timelineTime - offset; positive offset = camera started later than reference.
  Never "fix" the implementation to match old docs.
- New Swift files: register via project.yml + `xcodegen` (2.45.3 verified clean).

## From follow-up run (2026-06-12)
- Swift 6 language mode + SWIFT_STRICT_CONCURRENCY=complete are set in
  project.yml base settings. New code must compile with zero concurrency
  diagnostics. @unchecked Sendable is allowed ONLY with a real lock /
  serialization story + one-line invariant comment (see EndBumperCache,
  BackgroundState, ExportSessionBox, ProjectStore -- NSLock; PanelCompositor
  -- private render queue). Never share one FFTSetup across child tasks;
  create task-local plans.
- Grepping xcodebuild output for concurrency diagnostics: filter to
  'warning:|error:' lines FIRST -- filenames like AudioExtractor.swift
  false-match 'actor' on raw compile lines.
- swift-snapshot-testing is pinned via exactVersion in project.yml (test
  target only); Package.resolved is gitignored, so project.yml IS the pin.
  To intentionally change rendering, delete the affected __Snapshots__ PNGs,
  re-run to record, commit the new ones, and run twice to prove stability.
- A-B loop state is deliberately session-only and count-in / export-mirror
  prefs live in UserDefaults -- adding any of these to CoreoProject's Codable
  schema is a data-model change needing JMT approval.
