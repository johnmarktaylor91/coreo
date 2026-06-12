# Coreo Gotchas & Edge Cases

<!-- Agents: READ THIS before making changes. Append as you discover things. -->
<!-- Format: - [MODULE] GOTCHA: <description> -->

- [Workspace] @MainActor classes cannot call instance methods from deinit — deinit is nonisolated. Do NOT put tearDown logic in deinit. Use explicit cleanup or rely on ARC deallocation of AVPlayer instances.
- [Export] AnnotationCompositor uses UIKit (CALayer, UIColor), NOT SwiftUI. Cannot use `Color(hex:)` from the SwiftUI extension. Has its own private `UIColor(hexString:)` init.
- [Build] Xcode 26 simulators are iPhone 17 series, not iPhone 16. Destination: `platform=iOS Simulator,name=iPhone 17 Pro`
- [Build] `presentationCompactAdaptation` requires iOS 16.4+. Our target is iOS 16.0. Use `.frame()` instead for popover sizing.

## From full-scope improve run (2026-06-11)
- `-only-testing:CoreoTests/UnitTests` matches a CLASS named UnitTests, not the
  UnitTests/ directory -- it silently runs zero tests. Run the suite unfiltered.
- After Xcode updates: `sudo xcodebuild -runFirstLaunch` (needs admin) AND the
  matching iOS simulator platform (`xcodebuild -downloadPlatform iOS`, ~8.5GB)
  or destination resolution fails with "Supported platforms ... is empty".
- EDGE-CASES.md / PERFORMANCE.md at repo root described fixes that never existed
  in code (pre-run doc drift). Treat .project-context/improve/reports/ + git
  history as ground truth; those two docs need a rewrite pass.
- FFT sign convention (D1, locked by engine e2e test): clipLocalTime =
  timelineTime - offset; positive offset = camera started later than reference.
  Never "fix" the implementation to match old docs.
- New Swift files: register via project.yml + `xcodegen` (2.45.3 verified clean).
