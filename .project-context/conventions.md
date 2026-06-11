# Coreo Conventions

## Naming
- Types: `UpperCamelCase` — `SyncEngine`, `VideoClip`, `DualPlayerView`
- Functions/properties: `lowerCamelCase` — `extractAudio(from:)`, `syncOffset`
- Files: one primary type per file, file name matches type — `SyncEngine.swift`
- Constants: `lowerCamelCase` for instance/static, `UPPER_SNAKE` only for truly global constants (rare)
- Protocols: noun or adjective — `Syncable`, `TimelineControllable`
- Extensions: `TypeName+Context.swift` — `AVAsset+Extensions.swift`

## Error Handling
- Define domain errors as enums conforming to `Error`: `SyncError`, `CaptureError`, `ExportError`
- Use `throws` / `async throws` — propagate errors to the call site, handle in the view layer
- Never silently swallow errors — at minimum log with `os.Logger`
- Use `Result` only when storing errors for later; prefer `throws` for immediate propagation
- User-facing error messages go through a centralized `ErrorPresenter` — no raw error strings in views

## Testing Patterns
- Unit tests in `CoreoTests/UnitTests/`, integration tests in `CoreoTests/IntegrationTests/`
- Test fixtures (short .mov clips) in `CoreoTests/Fixtures/` — committed to repo, kept small (<2MB each)
- Use `XCTestCase` with descriptive method names: `test_syncEngine_findsCorrectOffset_whenClapAtDifferentTimes()`
- Mock AVFoundation where needed via protocol abstractions (e.g., `AudioExtractable` protocol)
- Async tests use `async throws` test methods (Xcode 15+ native support)
- Sync engine accuracy tests: assert offset within ±50ms tolerance

## Import Order
1. Foundation / UIKit / SwiftUI (Apple frameworks)
2. AVFoundation / Accelerate / other system frameworks
3. Local project modules (if using @testable import in tests)
Separated by blank lines. No wildcard imports.

## Documentation
- `///` doc comments on all public types and methods
- Use `- Parameter name:` and `- Returns:` markup for function docs
- `// MARK: - Section` to divide long files into logical sections
- File-level `//` comment at the top of files where the purpose isn't obvious from the type name

## Tooling
- **swiftlint** enforces style rules — all code must pass `swiftlint` with zero warnings
- **swiftformat** enforces formatting — all code must pass `swiftformat --lint .`
- **xcbeautify** for readable xcodebuild output — pipe all xcodebuild commands through it
- **fastlane** for build/test/deploy automation

## Git
- Commit messages: imperative mood, <72 chars first line — "Add audio cross-correlation engine"
- Branch naming: `codex/<task-id>` for Codex tasks, `feat/<name>` for manual work
- One logical change per commit — don't mix unrelated changes
- No force-push to `main`
