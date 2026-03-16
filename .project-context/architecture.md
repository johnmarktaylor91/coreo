# Coreo Architecture

## Module Map
- **App/** — Entry point, root navigation, app lifecycle
- **Models/** — Core data types: `Project`, `VideoClip`, `Annotation`. SwiftData models. No business logic.
- **Capture/** — AVCaptureSession management, camera UI, photo library import. Produces `VideoClip` file URLs.
- **Sync/** — Audio-based alignment engine. Extracts PCM from two clips, runs cross-correlation, outputs a time offset. Pure computation, no UI.
- **Playback/** — Dual AVPlayer coordination with shared timeline. Side-by-side and PiP layouts. Annotation overlay during playback. Variable speed (0.25x–2x).
- **Annotations/** — CRUD UI for timestamped text notes. Reads/writes `Annotation` models.
- **Export/** — Composites video + annotation overlay into shareable clip via AVAssetExportSession.
- **Storage/** — SwiftData persistence layer, file management for video assets in app sandbox.
- **Utilities/** — Time formatting, AVAsset convenience extensions.

## Data Flow
1. **Capture/Import** → video files land in app sandbox → `VideoClip` records created
2. **Project creation** → user groups 2 clips into a `Project`
3. **Sync** → `SyncEngine` takes two `VideoClip` assets → extracts audio → cross-correlates → writes `syncOffset` back to clips
4. **Playback** → `SyncedPlayerController` reads clips + offsets → drives two AVPlayers in lockstep → `TimelineView` shows unified scrub bar with `Annotation` markers
5. **Annotate** → user taps timeline → creates `Annotation` at current timestamp → persisted via SwiftData
6. **Export** → `ExportManager` composites selected angle + annotation text overlay → outputs .mov for sharing

## Key Abstractions
- **Project** — Top-level container. Has a name, creation date, exactly 2 `VideoClip`s, and 0+ `Annotation`s. The unit of work.
- **VideoClip** — Represents one video file. Holds: file URL, duration, `syncOffset` (TimeInterval, seconds relative to project timeline origin). Invariant: offset is set by SyncEngine, not manually.
- **Annotation** — Timestamped note. Holds: text, timestamp (in project timeline coordinates), optional reference to which angle. Invariant: timestamp is in unified project time, not per-clip time.
- **SyncedPlayerController** — The brain of playback. Owns two AVPlayers, translates unified timeline position to per-clip seek positions using sync offsets. Must handle: play/pause, seek, rate changes, end-of-clip edge cases.
- **SyncEngine** — Stateless computation. Input: two AVAssets. Output: TimeInterval offset. Should be cancellable (async/await with Task).

## Dependency Graph
```
App → Capture, Playback, Annotations, Storage
Capture → Models, Storage (writes clips)
Sync → Models (reads clips, writes offsets), Utilities
Playback → Models, Annotations, Utilities
Annotations → Models, Storage
Export → Models, Playback (borrows timeline logic), Utilities
Storage → Models
```
No circular dependencies. Sync and Playback are independent — Sync runs once, Playback reads the result.

## Known Complexity
- **Audio cross-correlation** (Sync/) — DSP math, must handle: different sample rates, stereo→mono conversion, noise, silence. The hardest algorithmic piece.
- **Dual AVPlayer synchronization** (Playback/) — AVPlayer seek is async and imprecise. Keeping two players in sub-frame sync during scrubbing and rate changes is fiddly. May need CMTimebase linking.
- **Memory pressure** — Two simultaneous video playback streams + audio extraction buffers. Must stream, not bulk-load.
- **Export compositing** — Overlaying annotation text at correct timestamps onto video requires AVVideoComposition with custom compositor or CALayer tree.
