# Coreo — Claude Code Architect Briefing

## Project Overview
Coreo is an iOS app for salsa, bachata, and kizomba dancers to record, sync,
and annotate multi-angle dance videos. Users film the same combo from two phone
angles, Coreo syncs the footage via audio analysis, and they review both angles
simultaneously with timestamped annotations. $4.99 one-time purchase, no cloud,
no accounts.

## Architecture
See `.project-context/architecture.md` for the full map.

Key entry points:
- App entry: `Coreo/App/CoreoApp.swift`
- Video capture: `Coreo/Capture/` (AVFoundation camera pipeline)
- Sync engine: `Coreo/Sync/` (audio-based multi-angle alignment)
- Playback: `Coreo/Playback/` (side-by-side / PiP with shared timeline)
- Annotations: `Coreo/Annotations/` (timestamped notes on timeline)
- Models: `Coreo/Models/` (Project, VideoClip, Annotation data types)
- Tests: `CoreoTests/` — `xcodebuild test`
- Build: `xcodebuild -scheme Coreo -sdk iphonesimulator build`

## How to Read This Codebase
- Start with `Models/` to understand core data types (Project, VideoClip, Annotation)
- Complexity lives in `Sync/` (audio cross-correlation algorithm) and `Playback/` (synchronized AVPlayer coordination)
- `Capture/` and `Annotations/` are relatively straightforward SwiftUI + AVFoundation
- Everything is in flux — greenfield project, nothing is stable yet

## Testing Tiers
```
# Tier 1 — Fast (run on every change)
xcodebuild test -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CoreoTests/UnitTests 2>&1 | xcpretty

# Tier 2 — Medium (run when module boundaries change)
xcodebuild test -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | xcpretty

# Tier 3 — Full (run during downtime / before release)
swiftlint lint --strict && xcodebuild test -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | xcpretty
```

## Dispatch Configuration

### Branch Strategy
Codex works on feature branches: `codex/<task-id>`
Default: one branch at a time besides main. Don't spawn extras unless asked.

### Task ID Convention
Descriptive kebab-case: `add-sync-engine`, `fix-playback-drift`, `add-annotation-ui`

### Quality Gates (every Codex task must pass)
```
swiftlint lint --strict
xcodebuild build -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | xcpretty
xcodebuild test -scheme Coreo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CoreoTests/UnitTests 2>&1 | xcpretty
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
