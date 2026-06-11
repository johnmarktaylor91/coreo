# Coreo Gotchas & Edge Cases

<!-- Agents: READ THIS before making changes. Append as you discover things. -->
<!-- Format: - [MODULE] GOTCHA: <description> -->

- [Workspace] @MainActor classes cannot call instance methods from deinit — deinit is nonisolated. Do NOT put tearDown logic in deinit. Use explicit cleanup or rely on ARC deallocation of AVPlayer instances.
- [Export] AnnotationCompositor uses UIKit (CALayer, UIColor), NOT SwiftUI. Cannot use `Color(hex:)` from the SwiftUI extension. Has its own private `UIColor(hexString:)` init.
- [Build] Xcode 26 simulators are iPhone 17 series, not iPhone 16. Destination: `platform=iOS Simulator,name=iPhone 17 Pro`
- [Build] `presentationCompactAdaptation` requires iOS 16.4+. Our target is iOS 16.0. Use `.frame()` instead for popover sizing.
