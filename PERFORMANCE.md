# Coreo Performance & Reliability

## Optimization Sprint Summary (2026-03-17)

### Issues Found: 49 total
| Severity | Found | Fixed | Deferred |
|----------|-------|-------|----------|
| Critical | 3     | 3     | 0        |
| High     | 12    | 10    | 2        |
| Medium   | 18    | 6     | 12       |
| Low      | 16    | 0     | 16       |

### Critical Fixes (all done)
1. **Retain cycle / time observer leak** — WorkspaceViewModel had no tearDown path called reliably. Time observers, Combine sinks, and notification observers were never cleaned up. Fixed: `.onDisappear` calls `tearDown()`, which removes all observers, pauses players, cancels export, and clears subscriptions.
2. **tearDown() never called on any code path** — The back button paused but never tore down. Fixed: `.onDisappear` modifier on WorkspaceView.
3. **Time observer closure retain cycle** — `self` -> `players` -> observer -> weak self, but token held by self. Fixed by ensuring tearDown breaks the cycle reliably.

### High Fixes (10 of 12)
1. **No `preferredForwardBufferDuration`** — 6 AVPlayers buffering 30-60s of HD video each = 1-2 GB RAM. Fixed: set to 5 seconds per player item.
2. **No background/foreground handling** — Players decoded frames into nothing when backgrounded. Fixed: observe `didEnterBackground` / `willEnterForeground`, pause/resume accordingly.
3. **No `beginBackgroundTask` in export** — Export silently failed when backgrounded. Fixed: request background execution time before export starts.
4. **No `autoreleasepool` in AudioExtractor** — CMSampleBuffer temporaries accumulated across the entire read loop for a 5-minute clip. Fixed: wrap each iteration.
5. **Double copy in AudioExtractor** — Sample data was copied twice (CMBlockBuffer -> Data -> [Float]). Fixed: single copy directly into [Float] array.
6. **No `reserveCapacity` on audio samples array** — Repeated reallocations for 2.4M samples. Fixed: pre-compute from track duration.
7. **Scalar loop in FFT complex multiply** — 72k iterations of manual multiply replaced with single `vDSP_zvmul` call.
8. **CGImage not released in PersonDetector** — Each ~6MB frame lingered while next was generated. Fixed: autoreleasepool per iteration.
9. **Division by zero in speed segments** — `segment.rate == 0` would produce Infinity. Fixed: guard `rate > 0`.
10. **Export cancellation race** — Catching both `CancellationError` and `ExportError.cancelled` without showing error alert.

### High Deferred (2)
- **New CAShapeLayer on every updateUIView** (VideoPanelView) — Needs UIView subclass refactor to cache mask layer. Impact: allocation churn at 20-120 objects/sec. Not a crash risk.
- **Thumbnail Data re-decoded on every SwiftUI redraw** (VideoThumbnailView) — Needs @State image caching pattern. Impact: JPEG decompressions during scroll. Not a crash risk.

### Medium Fixes (6)
1. **Export task not cancelled on tearDown** — Added `exportTask?.cancel()`.
2. **Exported temp file leaked** — Added `cleanUpExportedFile()` called on share sheet dismiss.
3. **Lifecycle observer cleanup** — Background/foreground observers removed in tearDown.
4. **syncOffsets bounds check** — Time observer now guards `validReferenceIndex < syncOffsets.count`.
5. **audioSourceIndex clamped** — Clamped to `players.count - 1` in setupPlayers.
6. **Cancellation support in sync/crop** — Added `Task.checkCancellation()` to AudioSyncEngine and PersonDetector loops.

### Medium Deferred (12)
- FFT intermediate arrays not scoped for early release
- Full correlation array allocated but unused in FFTHelper
- Unbounded concurrent correlations in AudioSyncEngine (cap at 2)
- Crop detection errors silently swallowed
- Crop results not cached across workspace re-entries
- Export cancellation doesn't cancel AVAssetExportSession itself
- CMTimeRange insertTime negative (theoretical, invariant-protected)
- referenceVideoIndex can go stale if videos removed
- videos.count == syncOffsets.count invariant not enforced at model level
- Pixel format mismatch between bumper (ARGB) and compositor (BGRA)
- PencilKit annotation re-renders every frame
- Audio session active at launch, never deactivated

---

## Known Performance Characteristics

### Memory
- **Workspace with 6 videos**: ~200-400 MB expected (6 AVPlayers with 5s forward buffer each)
- **Audio sync**: ~40 MB peak (reference + 2 concurrent correlations + FFT intermediaries)
- **Person detection**: ~20 MB peak (1 CGImage at 1280px + Vision inference buffers)
- **Export**: ~100 MB peak (CIContext + source pixel buffers + output buffer)

### Timing
- **Audio sync**: <2s for typical 3-5 min clips (8kHz downsample, vDSP FFT)
- **Smart crop**: 3-7s per video (sequential frame processing, ~72 frames at 2.5s intervals)
- **Export**: Varies by duration and resolution. 1920x1080, 3min, 2 videos: ~30-60s

### Known Limitations
- Smart crop processes frames sequentially per video (concurrent across videos via TaskGroup). Making per-video frame processing concurrent would cut time to ~1-2s per video but requires memory bounding.
- Export annotation overlay is temporarily disabled (incompatible with custom AVVideoCompositing). Annotations will be integrated into PanelCompositor.
- No periodic drift re-sync between players during playback. If players drift >0.03s, user must pause/play to re-sync.

---

## Recommended Test Scenarios

### Memory Pressure
1. Import 6 landscape 1080p videos, enter workspace, monitor memory in Instruments
2. Play all 6 simultaneously for 2 minutes, verify no jetsam
3. Export while playing music in background, verify export completes

### Background/Foreground
1. Start playback, background the app, return — verify playback resumes
2. Start export, background the app — verify export completes (within 30s background time)
3. Background during sync — verify sync doesn't continue wasting CPU

### Edge Cases
1. Import a video with no audio track — sync should error gracefully
2. Export with speed segment at 0.25x — verify correct duration
3. Navigate back from workspace rapidly — verify no zombie observers
4. Delete source video from Photos after import — verify graceful failure
