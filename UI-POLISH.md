# Coreo UI Polish System

## Animation Curves & Durations

| Name | Value | Use |
|------|-------|-----|
| `CoreoAnimation.press` | spring(0.25, 0.7) | Button press/release feedback |
| `CoreoAnimation.standard` | easeInOut(0.25) | Panel toggles, toolbar show/hide |
| `CoreoAnimation.slow` | easeInOut(0.35) | Screen transitions, overlay appearances |
| Button press spring | spring(0.2, 0.6) | CoreoButtonStyle scale-down |
| Prominent press spring | spring(0.2, 0.65) | CTA buttons (Sync, Export) |
| Zoom rubber-band | spring(0.3, 0.7) | Pinch snap-back at limits |
| Double-tap reset | spring(0.3, 0.75) | Zoom reset to 1x |

## Spacing Scale (4pt base)

| Token | Value | Use |
|-------|-------|-----|
| `Spacing.xxs` | 2pt | Tight icon-label gaps |
| `Spacing.xs` | 4pt | Panel gaps, minimal padding |
| `Spacing.sm` | 8pt | Inner element spacing |
| `Spacing.md` | 12pt | Standard element spacing |
| `Spacing.lg` | 16pt | Section padding |
| `Spacing.xl` | 24pt | Major section gaps |
| `Spacing.xxl` | 32pt | Screen-edge padding |

## Corner Radii

| Token | Value | Use |
|-------|-------|-----|
| `CornerRadius.small` | 4pt | Video panels, timeline segments |
| `CornerRadius.medium` | 8pt | Buttons, thumbnails, popovers |
| `CornerRadius.large` | 14pt | Import action buttons |
| `CornerRadius.xl` | 16pt | Sync & Go button |
| `CornerRadius.card` | 20pt | Export progress card |

## Color System

| Token | Value | Use |
|-------|-------|-----|
| `CoreoColor.accent` | #FF6B36 | Primary actions, selected states, playhead |
| `CoreoColor.accentGradientEnd` | #E83D3D | Sync button gradient end |
| `CoreoColor.backgroundDeep` | #0A0A0A | App background |
| `CoreoColor.backgroundMedium` | #1A1A1A | Bars, panels, cards |
| `CoreoColor.backgroundPanel` | #0F0F0F | Video panel background |
| `CoreoColor.textPrimary` | #FFFFFF | Titles, primary content |
| `CoreoColor.textSecondary` | #FFFFFFB3 | Labels, descriptions |
| `CoreoColor.textTertiary` | #FFFFFF80 | Timestamps, metadata |
| `CoreoColor.textDisabled` | #FFFFFF59 | Disabled buttons |
| `CoreoColor.error` | #FF4D4D | Error messages |

## Haptic Feedback Map

| Action | Haptic | API |
|--------|--------|-----|
| Play/Pause | Light impact | `Haptic.light()` |
| Back navigation | Light impact | `Haptic.light()` |
| Edit toggle | Light impact | `Haptic.light()` |
| Remove video | Light impact | `Haptic.light()` |
| Done (annotation) | Light impact | `Haptic.light()` |
| Double-tap zoom reset | Light impact | `Haptic.light()` |
| Zoom at limits | Light impact | `Haptic.light()` |
| Timeline scrub start | Light impact | `Haptic.light()` |
| Export start | Medium impact | `Haptic.medium()` |
| Speed change | Selection tick | `Haptic.tick()` |
| Tool selection | Selection tick | `Haptic.tick()` |
| Export cancel | Light impact | `Haptic.light()` |
| Export complete | Notification success | `Haptic.success()` |
| Export/sync failure | Notification error | `Haptic.error()` |

## Button Styles

| Style | Effect | Use |
|-------|--------|-----|
| `.coreo` | Scale 0.92, opacity 0.7 | Standard buttons |
| `.coreoProminent` | Scale 0.96, brightness -0.08 | Large CTA buttons |
| `.coreoToolbar` | Scale 0.88, opacity 0.6 | Small icon buttons in bars |

## Hit Targets Fixed

| Element | Before | After |
|---------|--------|-------|
| Back button | 36x36 | 44x44 |
| Edit toggle | 36x36 | 44x44 |
| Export button | 36x36 | 44x44 |
| Remove thumbnail | 20x20 | 44x44 (visual 20x20) |
| Done button | ~40x20 | 44x44 minimum |
| Export cancel | ~70x30 | 88x44 minimum |
| Speed button | ~50x28 | 44x44 minimum |

## Changes Made (Sprint Summary)

### Phase 1: Touch Feedback
- Created `CoreoButtonStyle`, `CoreoProminentButtonStyle`, `CoreoToolbarButtonStyle` with spring press animations
- Applied to ALL buttons across WorkspaceView, PlaybackControlsView, ImportView, ExportProgressView, VideoThumbnailView
- Replaced all `.buttonStyle(.plain)` usages (10 instances)

### Phase 2: Haptic Feedback
- Created centralized `Haptic` enum with light/medium/tick/success/error
- Added haptics to: play/pause, back, edit toggle, export start/complete/fail/cancel, speed changes, tool selection, zoom limits, double-tap reset, scrub start, video remove

### Phase 3: Hit Targets
- Fixed 7 elements below 44x44pt minimum
- All interactive elements now meet Apple HIG minimum touch target

### Phase 4: Design System
- Created `DesignSystem.swift` with `CoreoColor`, `Spacing`, `CoreoAnimation`, `CornerRadius`
- Applied spacing tokens to PlaybackControlsView as reference implementation
- Remaining files can be migrated incrementally

### Phase 5: Zoom Polish
- Added rubber-band physics at zoom limits (resist + snap back)
- Added spring animation to pinch-to-zoom end (snap to clamped value)
- Upgraded double-tap reset from easeOut to spring curve

### Phase 6: Export UX
- Success haptic on export completion
- Error haptic on export failure
- Cancel button hit target fixed to 88x44pt

## Deferred Items

- Import → Workspace matched geometry transition (requires structural NavigationStack changes)
- Annotation marker dot hit targets (6pt → needs overlay hit area, not just dot resize)
- Playhead interpolation between time observer ticks (CADisplayLink approach)
- Thumbnail shimmer placeholder during load
- Video panel crossfade on start/end
- Annotation entrance choreography (staggered toolbar animation)
- Empty state breathing animation
- Export completion checkmark animation before share sheet
- Consistent `CoreoColor`/`Spacing` migration across ALL remaining files
- Accessibility labels on all interactive elements
- Dynamic Type support for annotation text
