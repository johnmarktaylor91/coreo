# Coreo UI Polish System

Purpose: inventory the design tokens, tactile feedback, and accessibility coverage that exist in current SwiftUI code. This is a source-derived reference for maintainers and agents, not an aspirational checklist.

Grounded in code as of 2026-06-12 (post follow-up run). If code changes materially, regenerate rather than patch.

## Token Sources

| Token group | Defining file |
|---|---|
| Colors, spacing, animation, corner radii | `Coreo/UI/DesignSystem.swift:13` |
| Button press styles | `Coreo/UI/CoreoButtonStyle.swift:12` |
| Haptics vocabulary | `Coreo/UI/Haptics.swift:9` |
| Export aspect presets | `Coreo/Export/ExportSettings.swift:8` |
| Annotation palette | `Coreo/Annotations/AnnotationModel.swift:295` |

## Colors

Defined in `Coreo/UI/DesignSystem.swift:13`.

| Token | Source value | Typical use |
|---|---:|---|
| `CoreoColor.accent` | `Color(red: 1.0, green: 0.42, blue: 0.21)` | Primary actions, selected states, waveform center line |
| `CoreoColor.accentGradientEnd` | `Color(red: 0.91, green: 0.24, blue: 0.24)` | Sync button gradient end |
| `CoreoColor.backgroundDeep` | `Color(red: 0.04, green: 0.04, blue: 0.04)` | Workspace and waveform sheet background |
| `CoreoColor.backgroundMedium` | `Color(red: 0.1, green: 0.1, blue: 0.1)` | Bars, popovers, panels |
| `CoreoColor.backgroundPanel` | `Color(red: 0.06, green: 0.06, blue: 0.06)` | Video panel and waveform strip background |
| `CoreoColor.textPrimary` | `Color.white` | Primary text |
| `CoreoColor.textSecondary` | `Color.white.opacity(0.7)` | Secondary labels |
| `CoreoColor.textTertiary` | `Color.white.opacity(0.5)` | Metadata and empty waveform labels |
| `CoreoColor.textDisabled` | `Color.white.opacity(0.35)` | Disabled text/icon color |
| `CoreoColor.error` | `Color(red: 1.0, green: 0.3, blue: 0.3)` | Error text |

## Spacing

Defined in `Coreo/UI/DesignSystem.swift:31`. Usage examples include playback controls, workspace edit tools, annotation overlay, and waveform sync (`Coreo/Workspace/PlaybackControlsView.swift:27`, `Coreo/Workspace/WorkspaceView.swift:158`, `Coreo/Annotations/AnnotationOverlayView.swift:97`, `Coreo/Workspace/WaveformSyncNudgeView.swift:25`).

| Token | Value |
|---|---:|
| `Spacing.xxs` | 2 pt |
| `Spacing.xs` | 4 pt |
| `Spacing.sm` | 8 pt |
| `Spacing.md` | 12 pt |
| `Spacing.lg` | 16 pt |
| `Spacing.xl` | 24 pt |
| `Spacing.xxl` | 32 pt |

## Animation

Defined in `Coreo/UI/DesignSystem.swift:43`; button styles define their own press springs in `Coreo/UI/CoreoButtonStyle.swift:12`.

| Token or style | Value | Verified use |
|---|---|---|
| `CoreoAnimation.press` | `spring(response: 0.25, dampingFraction: 0.7)` | Defined but no current direct call found by source search. |
| `CoreoAnimation.standard` | `easeInOut(duration: 0.25)` | Edit tools, speed panel, speed popover transitions (`Coreo/Workspace/WorkspaceView.swift:187`, `Coreo/Workspace/WorkspaceView.swift:262`, `Coreo/Workspace/PlaybackControlsView.swift:177`) |
| `CoreoAnimation.slow` | `easeInOut(duration: 0.35)` | Sync button availability animation (`Coreo/Import/ImportView.swift:377`) |
| `.coreo` press | scale 0.92, opacity 0.7, spring 0.2/0.6 | Standard button style (`Coreo/UI/CoreoButtonStyle.swift:12`) |
| `.coreoProminent` press | scale 0.96, brightness -0.08, spring 0.2/0.65 | Large CTA style (`Coreo/UI/CoreoButtonStyle.swift:23`) |
| `.coreoToolbar` press | scale 0.88, opacity 0.6, spring 0.2/0.6 | Toolbar icon style (`Coreo/UI/CoreoButtonStyle.swift:33`) |
| Workspace reduce motion | nils two workspace-level 0.25s animations when Reduce Motion is enabled | `Coreo/Workspace/WorkspaceView.swift:17`, `Coreo/Workspace/WorkspaceView.swift:102` |

## Corner Radii

Defined in `Coreo/UI/DesignSystem.swift:56`.

| Token | Value | Verified use |
|---|---:|---|
| `CornerRadius.small` | 4 pt | Waveform strip background (`Coreo/Workspace/WaveformSyncNudgeView.swift:163`) |
| `CornerRadius.medium` | 8 pt | Annotation save button, export cancel, speed chips (`Coreo/Annotations/AnnotationOverlayView.swift:100`, `Coreo/Export/ExportProgressView.swift:80`, `Coreo/Workspace/PlaybackControlsView.swift:187`) |
| `CornerRadius.large` | 14 pt | Import action buttons (`Coreo/Import/ImportView.swift:289`) |
| `CornerRadius.xl` | 16 pt | Sync button (`Coreo/Import/ImportView.swift:374`) |
| `CornerRadius.card` | 20 pt | Defined; no current direct use found by source search. |

## Haptics

Defined in `Coreo/UI/Haptics.swift:9`.

| API | Generator | Intended vocabulary | Verified examples |
|---|---|---|---|
| `Haptic.light()` | `UIImpactFeedbackGenerator(style: .light)` | Play/pause, tool selection, navigation | Back, play/pause, scrub start, export cancel (`Coreo/Workspace/WorkspaceView.swift:161`, `Coreo/Workspace/PlaybackControlsView.swift:63`, `Coreo/Workspace/TimelineView.swift:341`, `Coreo/Export/ExportProgressView.swift:72`) |
| `Haptic.medium()` | `UIImpactFeedbackGenerator(style: .medium)` | Significant starts | Sync and export start (`Coreo/Import/ImportView.swift:350`, `Coreo/Workspace/WorkspaceView.swift:209`) |
| `Haptic.tick()` | `UISelectionFeedbackGenerator` | Selection changes, scrubbing markers | Tools, speed changes, loop state, waveform nudges (`Coreo/Annotations/AnnotationToolbar.swift:102`, `Coreo/Workspace/PlaybackControlsView.swift:213`, `Coreo/Workspace/PlaybackControlsView.swift:82`, `Coreo/Workspace/WaveformSyncNudgeView.swift:201`) |
| `Haptic.success()` | `UINotificationFeedbackGenerator.success` | Successful completion | Sync success, export success, media replacement success (`Coreo/Import/ImportViewModel.swift:273`, `Coreo/Workspace/ExportCoordinator.swift:93`, `Coreo/Workspace/WorkspaceViewModel.swift:658`) |
| `Haptic.error()` | `UINotificationFeedbackGenerator.error` | Failed or rejected action | Import cap/errors, loop too short, export errors (`Coreo/Import/ImportViewModel.swift:124`, `Coreo/Workspace/PlaybackControlsView.swift:84`, `Coreo/Workspace/ExportCoordinator.swift:105`) |

## Buttons And Hit Targets

| Element | Current target | Source |
|---|---:|---|
| Top bar back/edit/export icons | 44x44 frame plus content shape | `Coreo/Workspace/WorkspaceView.swift:166`, `Coreo/Workspace/WorkspaceView.swift:194`, `Coreo/Workspace/WorkspaceView.swift:212` |
| Playback play, loop, frame step, count-in | 44x44 frames | `Coreo/Workspace/PlaybackControlsView.swift:66`, `Coreo/Workspace/PlaybackControlsView.swift:87`, `Coreo/Workspace/PlaybackControlsView.swift:101`, `Coreo/Workspace/PlaybackControlsView.swift:153` |
| Playback speed button | min 44x44 | `Coreo/Workspace/PlaybackControlsView.swift:181` |
| Thumbnail remove | 20 pt visual inside 44x44 hit target | `Coreo/Import/VideoThumbnailView.swift:67` |
| Missing media Re-pick/Remove | minHeight 44 | `Coreo/Workspace/WorkspaceView.swift:402`, `Coreo/Workspace/WorkspaceView.swift:410` |
| Waveform Reset/Done and nudge buttons | minHeight 44; nudge minWidth 54 | `Coreo/Workspace/WaveformSyncNudgeView.swift:52`, `Coreo/Workspace/WaveformSyncNudgeView.swift:60`, `Coreo/Workspace/WaveformSyncNudgeView.swift:199` |
| Panel mirror/audio buttons | 44x44 frames | `Coreo/Workspace/VideoPanelView.swift:186` |
| Panel compact nudge buttons | 28x24 visual frames; no 44 pt frame | `Coreo/Workspace/VideoPanelView.swift:214` |

## Typography

There is no typography token enum in current code. Fonts are local SwiftUI choices:

| Pattern | Source |
|---|---|
| Monospaced time labels and speed labels | `Coreo/Workspace/PlaybackControlsView.swift:48`, `Coreo/Workspace/TimelineView.swift:271` |
| Large rounded count-in overlay | `Coreo/Workspace/WorkspaceView.swift:470` |
| Compact panel badges and nudge labels | `Coreo/Workspace/VideoPanelView.swift:117`, `Coreo/Workspace/VideoPanelView.swift:214` |
| Annotation text rasterization uses semibold system font scaled from authoring canvas width | `Coreo/Annotations/AnnotationRasterizer.swift:198` |

## Accessibility Coverage

| Area | Implemented coverage | Source |
|---|---|---|
| VoiceOver labels | Back, edit tools, export, play/pause, loop, count-in, frame step, speed, panel waveform/mirror/audio, timeline, annotation markers, annotation tools, waveform strips, and nudge buttons carry labels/values. | `Coreo/Workspace/WorkspaceView.swift:173`, `Coreo/Workspace/PlaybackControlsView.swift:73`, `Coreo/Workspace/PlaybackControlsView.swift:94`, `Coreo/Workspace/VideoPanelView.swift:157`, `Coreo/Workspace/TimelineView.swift:99`, `Coreo/Annotations/AnnotationMarkerView.swift:61`, `Coreo/Annotations/AnnotationToolbar.swift:120`, `Coreo/Workspace/WaveformSyncNudgeView.swift:184` |
| Selected traits | Annotation toolbar adds `.isSelected` for the active tool. | `Coreo/Annotations/AnnotationToolbar.swift:121` |
| 44 pt touch targets | Main navigation/playback controls, thumbnail remove, media recovery, waveform buttons, and panel utility buttons meet 44 pt targets. | `Coreo/Workspace/WorkspaceView.swift:169`, `Coreo/Workspace/PlaybackControlsView.swift:69`, `Coreo/Import/VideoThumbnailView.swift:82`, `Coreo/Workspace/WaveformSyncNudgeView.swift:207`, `Coreo/Workspace/VideoPanelView.swift:199` |
| Reduce Motion | Workspace-level edit and annotation mode animations are disabled when `accessibilityReduceMotion` is true. | `Coreo/Workspace/WorkspaceView.swift:17`, `Coreo/Workspace/WorkspaceView.swift:102` |
| Dynamic Type | Many labels use semantic SwiftUI fonts (`.headline`, `.caption`, `.body`), but some dense controls use fixed `system(size:)` fonts. There is no global Dynamic Type policy or size range. | `Coreo/Workspace/PlaybackControlsView.swift:54`, `Coreo/Workspace/VideoPanelView.swift:120`, `Coreo/Annotations/AnnotationToolbar.swift:108` |

## Export And Annotation Visual Tokens

| Token group | Values | Source |
|---|---|---|
| Export aspect presets | Landscape 1920x1080, Portrait 1080x1920, Square 1080x1080 with matching SF Symbols | `Coreo/Export/ExportSettings.swift:8` |
| Annotation palette | White, Red, Yellow, Cyan, Green, Orange | `Coreo/Annotations/AnnotationModel.swift:295` |
| Annotation fades | 0.2s fade in and 0.2s fade out for timed annotations | `Coreo/Annotations/AnnotationModel.swift:70` |
| End bumper | Dark background, centered "Coreo", 0.3s fade in/out, silent mp4 | `Coreo/Export/EndBumperGenerator.swift:31`, `Coreo/Export/EndBumperGenerator.swift:192` |

## Known Gaps

| Gap | Evidence |
|---|---|
| `CoreoAnimation.press` and `CornerRadius.card` are defined but currently unused. | `Coreo/UI/DesignSystem.swift:43`, `Coreo/UI/DesignSystem.swift:56` |
| Not every interactive element uses the custom button styles; some compact panel controls use `.plain`. | `Coreo/Workspace/VideoPanelView.swift:156`, `Coreo/Workspace/VideoPanelView.swift:226` |
| Compact panel nudge buttons are below 44 pt visual/touch size and lack explicit accessibility labels. | `Coreo/Workspace/VideoPanelView.swift:214` |
| Dynamic Type is partial; fixed-size fonts remain in dense controls and generated annotation text. | `Coreo/Workspace/VideoPanelView.swift:120`, `Coreo/Annotations/AnnotationRasterizer.swift:198` |
| Reduce Motion handling is applied at the workspace container level, but individual button-style springs do not read Reduce Motion. | `Coreo/Workspace/WorkspaceView.swift:102`, `Coreo/UI/CoreoButtonStyle.swift:17` |
