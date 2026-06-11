# Coreo Edge Cases & Known Limitations

## Edge Case Hardening Sprint (2026-03-17)

### Issues Found: 52 across import, sync, crop, export, persistence
### Fixed: 22 | Deferred: 30

---

## Crash Fixes (all done)

| Issue | File | Fix |
|-------|------|-----|
| NaN/Infinity duration from corrupt video | VideoAsset.swift | Guard `isFinite && > 0.1`, throw `.invalidDuration` |
| `Int(NaN)` in reserveCapacity | AudioExtractor.swift | Guard finite duration, fallback to 8192 |
| Out-of-bounds in finalizeProject | ImportViewModel.swift | Bounds check `index < output.offsets.count` |
| Division by zero in PanelCompositor | PanelCompositor.swift | Guard `extent.width > 0 && height > 0` |
| Division by zero in LayoutEngine | LayoutEngine.swift | Clamp rowHeight/panelWidth to min 1pt |
| timeObserver removed from wrong player | WorkspaceViewModel.swift | Store `timeObserverPlayerIndex` at install time |
| Speed segment rate == 0 division | ExportEngine.swift | Guard `rate > 0` before scaleTimeRange |

## Silent Wrong Output Fixes

| Issue | File | Fix |
|-------|------|-----|
| 1-video layout returned empty | LayoutEngine.swift | Handle `videoCount == 1` → full container rect |
| audioSourceIndex out of bounds | ExportEngine.swift | Call `project.sanitizeIndices()` at export start |
| Negative insertTime from float rounding | ExportEngine.swift | Clamp `max(0, syncOffset - timelineStart)` |
| Pixel format mismatch (ARGB vs BGRA) | EndBumperGenerator.swift | Aligned to BGRA everywhere |
| No-audio videos blocked import entirely | VideoAsset.swift | Audio track now optional, `audioBitrate: 0` if absent |
| No-audio videos broke sync pipeline | ImportViewModel.swift | Filter to audio-bearing videos for sync, flag no-audio as unreliable |
| Stale referenceVideoIndex/audioSourceIndex | CoreoProject.swift | Added `sanitizeIndices()` method |
| Zero-size video dimensions | VideoAsset.swift | Clamp to min 1x1 |

---

## Known Limitations

### Video Format Support
- **Supported codecs**: H.264, HEVC (H.265), ProRes — anything AVFoundation decodes
- **Supported containers**: .mp4, .mov, .m4v
- **Max tested resolution**: 4K (3840x2160)
- **HDR**: Not tone-mapped. HDR content may appear washed out when mixed with SDR. Export is SDR.
- **Variable frame rate (slow-mo)**: Supported for playback and export. Audio extraction handles VFR correctly through AVAssetReader's time-based output.

### Audio Requirements
- Videos **without audio** can be imported but cannot participate in automatic sync. They receive offset 0 and are flagged as unreliable for manual positioning.
- At least **2 videos with audio** are required for automatic sync.
- Audio is downsampled to **8 kHz mono** for sync. Original quality is preserved in export.
- **Silent audio** (all zeros) produces confidence 0 and offset 0 — flagged unreliable.

### Project Limits
| Dimension | Tested | Limit |
|-----------|--------|-------|
| Videos per project | 6 | 6 (LayoutEngine max) |
| Video duration | 5 min | No hard limit; export time scales linearly |
| Annotations | 20 | No hard limit; timeline may get cluttered beyond ~30 |
| Speed segments | 10 | No hard limit; overlapping segments may cause unexpected behavior |
| Export resolution | 1920x1080 | Configurable; higher = more memory + slower |

### Persistence
- Single project at a time (one save file)
- **No schema versioning yet** — app updates that change model fields will lose saved data
- Save is atomic (`.atomic` write option)
- Corrupted JSON → `load()` returns nil (user sees fresh state, previous work lost)
- Video file URLs are stored as absolute paths; if the source file is deleted, the project breaks

### Export
- **Annotations are not rendered in export** (temporarily disabled due to custom compositor incompatibility with AVVideoCompositionCoreAnimationTool)
- **Trim range is not applied** during export (model fields exist but export ignores them)
- Export survives app backgrounding for ~30 seconds (background task)
- Task cancellation cancels the Swift Task but not the underlying AVAssetExportSession

---

## Error Messages & Triggers

| Message | Trigger |
|---------|---------|
| "The file does not contain a video track." | Importing an audio-only file |
| "The video has an invalid or unreadable duration." | Corrupt video, duration NaN/Infinity, or < 0.1s |
| "Failed to generate a thumbnail image from the video." | Corrupt video where no frame can be decoded |
| "At least 2 videos with audio are needed for automatic sync." | < 2 videos have audio tracks |
| "Sync failed: [detail]" | Audio extraction failure, correlation failure |
| "Couldn't confidently match: [files]" | Sync confidence below 0.3 threshold |
| "Not enough reliable videos remain." | After removing unreliable videos, < 2 remain |
| "No videos to export." | Exporting an empty project |
| "Not enough disk space to complete the export." | < 500 MB free |
| "Export failed: [detail]" | AVAssetExportSession failure |
| "Export was cancelled." | User cancelled export |

---

## Deferred Items

### Will Fix Before Ship
- Schema versioning for CoreoProject persistence
- Annotations rendering in export (integrate into PanelCompositor)
- Trim range applied during export
- Silent audio detection (RMS threshold check before correlation)
- Cancel export actually cancels AVAssetExportSession
- Memory warning handler (release thumbnails, pause non-visible players)
- Validate video file existence on project load

### Known Won't Fix (v1)
- No support for > 6 videos per project
- No support for manual video positioning (drag on timeline)
- HDR → SDR tone mapping not implemented
- No project backup/versioning
- cropOverrides keyed by index (fragile on reorder)
- Speed segment overlap validation not enforced at model level
