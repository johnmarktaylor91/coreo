# Coreo — Claude Code Architect Briefing

## Project Overview
Coreo is a native iOS app for learning choreography from multi-angle video.
Users import 2-6 dance videos filmed from different angles, Coreo auto-syncs
them via FFT audio cross-correlation, displays them in an intelligent split-screen
layout with smart auto-crop, and supports time-stamped annotations (drawings,
text, arrows) that fade in/out at designated moments. Export produces a single
composited .mp4. $4.99 one-time purchase, no cloud, no accounts. See DESIGN.md
for full product spec.

## Architecture
See `.project-context/architecture.md` for the full map.

Two-screen design: Import (drop zone) → Workspace (preview + edit + export).

Key entry points:
- App entry: `Coreo/App/CoreoApp.swift`
- Import screen: `Coreo/Import/` (PHPicker, document picker, thumbnail display)
- Sync engine: `Coreo/Sync/` (FFT audio cross-correlation via Accelerate)
- Smart crop: `Coreo/Crop/` (Vision framework person detection)
- Workspace: `Coreo/Workspace/` (split-screen playback, unified timeline, WorkspaceViewModel)
- Annotations: `Coreo/Annotations/` (PencilKit drawing, text, arrows, time-ranged visibility)
- Speed/hold: `Coreo/Speed/` (per-segment speed control, frame freeze)
- Export: `Coreo/Export/` (AVMutableComposition pipeline, annotation compositor, end bumper)
- Models: `Coreo/Models/` (CoreoProject, VideoAsset, LayoutEngine)
- Tests: `CoreoTests/` — `xcodebuild test`
- Build: `xcodebuild -scheme Coreo build`

## How to Read This Codebase
- Start with `Models/CoreoProject.swift` and `Annotations/AnnotationModel.swift` for core data types
- Complexity lives in `Sync/AudioSyncEngine.swift` (FFT cross-correlation), `Workspace/WorkspaceViewModel.swift` (unified timeline + multi-player coordination), and `Export/ExportEngine.swift` (AVMutableComposition pipeline)
- `Import/` and `Speed/` are relatively straightforward SwiftUI
- Everything is in active development — initial build, nothing is stable yet

## Testing Tiers
```
# Tier 1 — Fast (run on every change)
xcodebuild test -scheme Coreo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:CoreoTests/UnitTests | xcbeautify

# Tier 2 — Medium (run when module boundaries change)
xcodebuild test -scheme Coreo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify

# Tier 3 — Full (run during downtime / before release)
swiftlint && swiftformat --lint . && xcodebuild test -scheme Coreo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify
```

## Dispatch Configuration

### Branch Strategy
Codex works on feature branches: `codex/<task-id>`
Default: one branch at a time besides main. Don't spawn extras unless asked.

### Task ID Convention
Descriptive kebab-case: `add-sync-engine`, `fix-playback-drift`, `add-annotation-ui`

### Quality Gates (every Codex task must pass)
```
swiftlint
swiftformat --lint .
xcodebuild test -scheme Coreo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify
```

## PR Workflow
```bash
# Create
gh pr create --title "<title>" --body "<description>"

# After merge (user says "merged" or "clean up")
git checkout main && git pull origin main
git branch -d <branch> && git remote prune origin
```

## What NOT to Dispatch
- Sync algorithm design decisions (discuss with user first)
- Changes to data model shape (Project, VideoClip, Annotation) without approval
- App Store / signing / provisioning profile changes
- StoreKit / IAP configuration
- CLAUDE.md, AGENTS.md, .project-context/*.md modifications
