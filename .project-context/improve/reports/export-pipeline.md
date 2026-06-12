# Export Pipeline Survey — Correctness, Fidelity, Performance

Survey agent lens: EXPORT PIPELINE (Coreo/Export/ + inputs: Models/LayoutEngine, Speed/, Annotations/, Crop/).
Method: static analysis only (xcodebuild broken on this machine). All line numbers verified against working tree at survey time (2026-06-11, main @ 9346ce5 + uncommitted files).

Labels: VERIFIED = read directly in code / provable from code paths. INFERRED = depends on AVFoundation runtime behavior or device behavior I could not execute.

---

## CRITICAL

### C1. Annotations are not rendered in export at all (core feature missing)
- **Files:** `Coreo/Export/ExportEngine.swift:120-125` (step 6 is a no-op comment), `:395-413` (`applyAnnotationOverlay` is dead code, never called); `Coreo/Export/AnnotationCompositor.swift` (entire file unreachable).
- **What's wrong (VERIFIED):** Step 6 of the pipeline deliberately skips annotations because `AVVideoCompositionCoreAnimationTool` is incompatible with a custom `AVVideoCompositing` (`PanelCompositor`). The dead `applyAnnotationOverlay` would throw/ be ignored if ever wired up. Time-stamped annotations are the product's "core differentiating feature" (DESIGN.md sec. 7), and EDGE-CASES.md:69 lists this as a known ship blocker.
- **Recommended change:** Render annotations inside `PanelCompositor` itself (the CoreAnimationTool path is a dead end with a custom compositor):
  1. Extend `PanelCompositionInstruction` with `annotationLayers: [AnnotationRenderItem]` where each item carries a pre-rasterized `CGImage` (drawing / text-with-pill / arrow, rendered once at export resolution before export starts) plus its `visibleTimeRange` mapped into **composition time** (see C3/H5 TimeMapper) and fade duration.
  2. In `compositeFrame`, for each item whose composition-time range contains `request.compositionTime`, compute opacity with the exact same math as `TimedAnnotation.opacity(at:)` (AnnotationModel.swift:46-76 — reuse the function, do not duplicate), then `CIImage(cgImage:)`, apply alpha (e.g. `CIColorMatrix` aVector), and composite over the panel result.
  3. Delete `applyAnnotationOverlay` and the CoreAnimationTool path entirely; repurpose `AnnotationCompositor` into the rasterizer (`buildAnnotationImage(_:renderSize:) -> CGImage`).
- **Blast radius:** PanelCompositor, PanelCompositionInstruction, ExportEngine step 6, AnnotationCompositor rewrite. No data-model change needed for text/arrow; drawing needs H4's canvasSize field.
- **Verification:** Unit test the opacity math reuse; integration test: export a 5s project with one text annotation at 1-2s, decode frames at 0.5s (expect absent), 1.5s (expect present), 2.5s (expect absent) via `AVAssetImageGenerator` and assert pixel diff in the text region.
- **Confidence:** High.

### C2. Crop rects (smart crop AND manual crop) are silently ignored in export
- **Files:** `Coreo/Export/PanelCompositor.swift:34` (`cropRect` declared), `:98-187` (`compositeFrame` never reads `config.cropRect`); populated at `Coreo/Export/ExportEngine.swift:356`; always non-nil in practice because `ImportViewModel.computeCropOverrides` (`Coreo/Import/ImportViewModel.swift:202,208-219`) writes smart-crop rects for every project at creation.
- **What's wrong (VERIFIED):** `PanelConfig.cropRect` is dead weight — `compositeFrame` aspect-fills the full frame regardless. Every export of a project where Vision found people ignores the auto-crop the user saw in preview. `videoSize` (PanelCompositor.swift:30) is also dead.
- **Recommended change:** In `compositeFrame`, after `image.oriented(orientation)`, if `config.cropRect != nil` convert the normalized top-left-origin rect (SmartCropEngine output, computed on the display-oriented frame because `PersonDetector` uses `appliesPreferredTrackTransform = true`, PersonDetector.swift:69) into CIImage y-up coords:
  `ciCrop = CGRect(x: crop.minX * extent.width, y: (1 - crop.maxY) * extent.height, w: crop.width * extent.width, h: crop.height * extent.height)` offset by `extent.origin`; `image = image.cropped(to: ciCrop)`; then run the existing fill/center math against the cropped extent. Remove dead `videoSize` or use it for validation.
- **Blast radius:** PanelCompositor only. Must land together with H1 (fit-vs-fill) so preview semantics are pinned first — see H1 for the semantic decision.
- **Verification:** Unit test the rect-space conversion (normalized top-left -> CI y-up) for 4 orientations; export test with a synthetic video (colored quadrants) + cropRect {0.5,0,0.5,1}, assert exported panel shows only right-half colors.
- **Confidence:** High.

### C3. Frame-hold exports as a black gap, not a frozen frame
- **Files:** `Coreo/Export/ExportEngine.swift:237-244` (`insertEmptyTimeRange` for holds); hold creation at `Coreo/Speed/SpeedControlView.swift:388-402` (rate 0, footprint 0.01s, `holdDurationSeconds` N).
- **What's wrong (VERIFIED):** `composition.insertEmptyTimeRange` inserts empty ranges into ALL tracks. With the custom compositor, `request.sourceFrame(byTrackID:)` returns nil during an empty range, the panel is `continue`d (PanelCompositor.swift:132-134), and the user gets N seconds of solid background (#0A0A0A) in every panel instead of the frozen frame DESIGN.md sec. 6 specifies. Audio going silent is correct; video going black is not.
- **Also (VERIFIED, cross-lens):** preview holds behave differently again — `applyLiveSpeedSegment` (WorkspaceViewModel.swift:513-529) pauses all players when rate==0, which stops the periodic time observer, so preview holds freeze FOREVER (`holdDurationSeconds` is never consulted in playback). Three behaviors exist: design (freeze N s), preview (freeze indefinitely), export (black N s).
- **Recommended change (export side):** Replace `insertEmptyTimeRange` for holds with a per-video-track freeze: for each composition video track, compute the track's source asset time at the hold point (holdStart-in-composition minus that track's insert offset, only if the track has media there), then `insertTimeRange(CMTimeRange(start: srcTime, duration: 1 frame), of: sourceTrack, at: holdPoint)` followed by `scaleTimeRange(thatOneFrameRange, toDuration: holdDuration)`. Keep `insertEmptyTimeRange` for the audio track only. Keep descending-start-order processing (it remains correct because `SpeedMap.addSegment` enforces non-overlap, SpeedSegmentModel.swift:78-115). Requires threading the per-track source `AVAssetTrack` + insert offsets from `buildComposition` into `applySpeedSegments`.
- **Blast radius:** ExportEngine steps 2-3 (signature change to pass source tracks/offsets). Fix preview hold separately (playback lens): resume after `holdDurationSeconds` via a scheduled task.
- **Verification:** Export a project with a 2s hold; `AVAssetImageGenerator` frames at holdStart+0.5s/1.5s must be identical to the frame at holdStart and non-black; total duration must equal originalDuration + 2s.
- **Confidence:** High.

### C4. Cancel doesn't cancel — export continues and the share sheet pops up later
- **Files:** `Coreo/Workspace/WorkspaceViewModel.swift:346-349` (`cancelExport` cancels the Swift Task only), `:320-343` (success path unguarded); `Coreo/Export/ExportEngine.swift` (zero `Task.checkCancellation()` calls; `exportSession` never exposed/cancelled, `:442-466`).
- **What's wrong (VERIFIED):** `await exportSession.export()` is not cancellation-aware and nothing calls `exportSession.cancelExport()`. After tapping Cancel, the overlay disappears (`isExporting=false`) but the export keeps burning CPU/battery/disk to completion, then `exportedVideoURL = url; showShareSheet = true` fires — the share sheet appears out of nowhere minutes later. The progress sub-task (`ExportEngine.swift:455-463`) is an unstructured `Task` that also ignores parent cancellation. EDGE-CASES.md:72 acknowledges half of this; the zombie-share-sheet half is unacknowledged.
- **Recommended change:**
  1. Wrap the export in `try await withTaskCancellationHandler(operation: { await exportSession.export() }, onCancel: { exportSession.cancelExport() })`.
  2. Add `try Task.checkCancellation()` between pipeline steps (after loadAssets, buildComposition, bumper, before performExport).
  3. In `startExport`'s success path: `guard !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }`.
  4. Also propagate cancellation into `EndBumperGenerator.generate` frame loop (it can run ~1-2s).
- **Blast radius:** ExportEngine.performExport + WorkspaceViewModel.startExport. No API change.
- **Verification:** Unit-testable by injecting a slow fake; manual: start export of a long project, cancel at ~20%, assert no share sheet within the next 2 minutes and tmp dir contains no `coreo_export_*` file.
- **Confidence:** High.

---

## HIGH

### H1. Preview letterboxes (aspect-fit), export crops (aspect-fill) — every panel differs
- **Files:** `Coreo/Workspace/VideoPanelView.swift:149,161` (`.resizeAspect` when no crop, `.resizeAspectFill`+mask when cropped) vs `Coreo/Export/PanelCompositor.swift:153-157` (`scale = max(scaleX, scaleY)` — always fill).
- **What's wrong (VERIFIED):** For a 16:9 video in a non-16:9 panel, preview shows the whole frame letterboxed; export crops the edges off. Dancers near frame edges get amputated in export while visible in preview. Conversely the preview's crop implementation (a CALayer mask in *panel* coordinates over an aspect-filled video, VideoPanelView.swift:171-190) is itself not "crop and fill" — it punches a window. Neither side matches the other or the design intent ("crop to activity region, maximize useful content" = crop then fill).
- **Recommended change:** Pin the semantic once: **panel content = (cropRect ?? full frame) aspect-FILLED into the panel**. Implement identically in both places: preview via `AVPlayerLayer` inside a container view that scales/offsets the layer to realize the crop (or keep mask approach but compute it from video-frame space), export via C2's crop-then-fill. Extract the shared geometry into one pure helper (e.g. `PanelGeometry.contentTransform(videoSize:cropRect:panelRect:) -> CGAffineTransform`) used by both, with unit tests. LayoutEngine's scoring (`totalVisibleArea`, LayoutEngine.swift:124-152) currently assumes aspect-FIT — update the score to match the chosen fill semantic or the "best variant" choice optimizes the wrong objective.
- **Blast radius:** VideoPanelView, PanelCompositor, LayoutEngine scoring. Visual behavior change in preview (intentional).
- **Verification:** Parity test: render one composition frame via PanelCompositor and screenshot the preview at the same time with same container aspect; assert identical content edges (synthetic quadrant video). Plus unit tests on the shared geometry helper.
- **Confidence:** High.

### H2. Layout is recomputed for a different container — grid variant and proportions can differ from preview
- **Files:** `Coreo/Export/ExportEngine.swift:319-337` (layout computed against `renderSize`, gap=4 px) vs `Coreo/Workspace/VideoGridView.swift:63-88` + `WorkspaceView.swift:42-57` (layout computed against on-screen geometry, gap=4 pt).
- **What's wrong (VERIFIED divergence-by-construction):** Same `LayoutEngine` but different `containerSize` inputs. For 3/5/6 videos the variant search (`[1,2]` vs `[2,1]`, `[2,3]` vs `[3,2]` vs `[3,3]`...) maximizes visible area *for that container aspect*, so a portrait phone preview (~390x600) and a 1920x1080 landscape export can legitimately pick different row configurations — the export looks structurally different from what the user approved. `layoutOverrides.panelRects` (normalized) stretch to a different aspect, distorting user-dragged proportions. The 4-unit gap is 4pt of ~390pt (~1.0% of width) in preview but 4px of 1920px (~0.2%) in export — gaps nearly vanish.
- **Recommended change:**
  1. Make the export aspect the single source of truth: the preview grid should render inside a container letterboxed to `exportAspectRatio` (WYSIWYG by construction), OR at minimum compute the export layout variant from the *preview* container's chosen variant (store the chosen rowConfig in the project when entering workspace / changing aspect).
  2. Scale the gap proportionally: `gap = 4 * renderSize.width / previewContainerWidth`, or define gap as a fraction (e.g. 0.5% of container min-dimension) in LayoutEngine used by both callers.
- **Blast radius:** ExportEngine.buildVideoComposition, VideoGridView, WorkspaceView (container shaping), possibly CoreoProject (persist chosen variant). Medium-size but high product value.
- **Verification:** Unit test: for fixed aspectRatios, assert `calculateLayout` rowConfig chosen for preview container == export container after the change; pixel test for gap fraction equality.
- **Confidence:** High on the mechanism; Medium on how often variants actually flip (depends on real aspect mixes — easy to confirm with a parameterized unit test sweep).

### H3. Pinch-zoom / pan framing is never exported (and never persisted)
- **Files:** `Coreo/Workspace/VideoPanelView.swift:30-39` (`currentScale`, `panOffset` are view `@State`), `:85-130` (gestures); nothing writes them to `project.cropOverrides`.
- **What's wrong (VERIFIED):** DESIGN.md sec. 3/4 says manual framing overrides "persist for the session/project". They live only in SwiftUI view state: lost on view recycle, never serialized, and the export pipeline has no idea they exist. A user who carefully reframes a panel gets the un-zoomed framing in the export.
- **Recommended change (data-model change, in scope):** On gesture end, convert (scale, panOffset, panelSize, videoSize) into a normalized crop rect in video-frame space and write it into `project.cropOverrides[index]` (replacing the smart-crop rect — this is exactly the "pinch disables auto-crop" behavior in DESIGN.md sec. 3). Export then consumes it via C2 with zero extra plumbing. Add `WorkspaceViewModel.setManualCrop(index:rect:)`.
- **Blast radius:** VideoPanelView (needs viewModel + index injection), WorkspaceViewModel, no schema change (cropOverrides already exists).
- **Verification:** UI test or manual: zoom panel 2x into top-left, export, assert exported panel matches preview region; unit test the gesture->cropRect math.
- **Confidence:** High.

### H4. AnnotationCompositor geometry is wrong on five axes (blocks C1 re-enable)
- **Files:** `Coreo/Export/AnnotationCompositor.swift` vs preview renderers.
- **What's wrong:**
  1. **Drawing coordinate space (VERIFIED):** PKDrawing strokes are in screen-point coords of the authoring container (PencilCanvasRepresentable draws on a canvas sized to the on-screen grid, `AnnotationOverlayView.swift:69-107`), but export rasterizes `pkDrawing.image(from: CGRect(origin: .zero, size: renderSize))` (`AnnotationCompositor.swift:146-148`) — a 390pt-wide drawing lands tiny in the top-left corner of a 1920px raster. Preview rasterizes from `containerSize` bounds (`AnnotationOverlayView.swift:283-292`) so it looks right on screen only.
  2. **No authoring-canvas record (VERIFIED data-model gap):** `DrawingAnnotation` (`AnnotationModel.swift:180-183`) stores only `drawingData`. Without the authoring canvas size there is NO correct mapping to any other resolution/device. Add `var canvasSize: CGSize` set at commit time (`WorkspaceViewModel.addDrawingAnnotation`, pass `containerSize`); export then uses `image(from: CGRect(origin:.zero, size: canvasSize))` scaled to renderSize.
  3. **Text anchor (VERIFIED):** preview centers the text view at `position` (SwiftUI `.position`, `TextAnnotationView.swift:64-67`); export uses `position` as the CATextLayer top-left (`AnnotationCompositor.swift:184-200`) — exported text shifts down-right by half its size.
  4. **Text style (VERIFIED divergence; font fallback INFERRED):** preview = system semibold + 2 shadows + black 35% pill (`TextAnnotationView.swift:46-63`); export = `CTFontCreateWithName("SFProText-Medium")` (likely an invalid PostScript name on iOS -> Helvetica fallback), no pill, no shadow, `.left` alignment, height from a chars/30 line guess. Use `UIFont.systemFont(ofSize:weight:.semibold)` and render the full pill+shadow into an image (per C1's rasterizer) instead of CATextLayer.
  5. **Arrow geometry + scale basis (VERIFIED):** export headLength 16/width 10 scaled by `renderSize.width/375` (`AnnotationCompositor.swift:221,245-256`) vs preview `headLength = max(lineWidth*4,12)`, +-30 deg wings, shaft shortened by half headLength (`ArrowAnnotationView.swift:109-184`). The `/375` assumption is wrong on every modern device (390/393/430pt) and ignores the actual container the user drew on. Scale should be `renderSize.width / authoringContainerWidth` — store container size with text/arrow annotations too, or normalize lineWidth/fontSize as fractions of container width at creation.
- **Recommended change:** Single shared annotation renderer (pure function) that takes (annotation, targetSize, authoringSize) and produces identical output for preview (SwiftUI Image/Canvas) and export (CGImage for C1). Add `canvasSize`/authoring-size to the annotation model (FULL OVERRIDE in effect; persistence has no schema versioning yet per EDGE-CASES.md:64 — coordinate with persistence lens).
- **Blast radius:** AnnotationModel (+field), WorkspaceViewModel (capture size), AnnotationCompositor rewrite, preview annotation views optionally refactored onto the shared renderer.
- **Verification:** Golden-image unit tests: render annotation at 390pt container and at 1920px export with same normalized inputs; downscale and assert SSIM/pixel match within tolerance.
- **Confidence:** High (items 1,3,5), Medium (4's font fallback specifics).

### H5. Annotation fade timing ignores speed/hold remap and the bumper (blocks C1 re-enable)
- **Files:** `Coreo/Export/AnnotationCompositor.swift:326-402` (keyTimes normalized against original `timelineDuration`); `ExportEngine.swift:80-104` (speed/holds and bumper change composition duration before annotations would apply).
- **What's wrong (VERIFIED, latent):** Annotation times are authored in timeline seconds, but the exported composition's clock is warped by `scaleTimeRange` (speed), insertions (holds), and extended by the bumper. The keyframe normalization divides by the *unwarped* timeline duration — any project with speed segments would fade annotations at the wrong moments; persistent annotations (`fillMode = .forwards`, values [1,1]) stay visible OVER the end bumper.
- **Recommended change:** Build a `TimeMapper` (pure struct) constructed from `(timelineStart, speedSegments)` exposing `func exportTime(forTimeline t: Double) -> Double` (piecewise linear: identity outside segments, rate-scaled inside, +holdDuration shifts at hold points) and `var mainContentDuration: Double`. Use it for annotation ranges in C1, and add a unit-test suite (this is also the single-source-of-truth answer for determinism — today the timeline->media-time mapping is implemented 3 ways: preview live rates in `WorkspaceViewModel.applyLiveSpeedSegment`, export `applySpeedSegments`, annotation keyframes). Clamp annotation visibility to main content; never over the bumper.
- **Blast radius:** New utility + ExportEngine + AnnotationCompositor; preview can adopt it later.
- **Verification:** Unit tests: segment [10,20]@0.5x -> exportTime(15)==20, exportTime(25)==35; hold 2s at 5 -> exportTime(6)==8.
- **Confidence:** High.

### H6. insertTimeRange uses import-time duration, not the actual track timeRange — composition build can throw
- **Files:** `Coreo/Export/ExportEngine.swift:180-189` (video: `assetDuration` from `project.videos[index].durationSeconds`), `:206-216` (audio inserted with the *video* duration range).
- **What's wrong (INFERRED, well-known AVFoundation behavior):** A movie's `duration` is the max across tracks; individual tracks (especially audio) are routinely a few hundredths shorter. `insertTimeRange` with a range extending beyond the source track's `timeRange` errors (or yields undefined tail behavior), failing the whole export with an opaque "Composition failed" for perfectly normal camera files. The stored `durationSeconds` also goes stale if the file is replaced.
- **Recommended change:** Load `try await sourceVideoTrack.load(.timeRange)` / `sourceAudioTrack.load(.timeRange)` and insert `CMTimeRangeGetIntersection(requested, trackRange)` for each track independently (audio gets its own clamped range, not the video's).
- **Blast radius:** `buildComposition` only.
- **Verification:** Unit/integration test with a generated asset whose audio track is 0.1s shorter than video (AVAssetWriter fixture); export must succeed.
- **Confidence:** Medium-High (failure mode inferred; the fix is harmless either way).

### H7. Backgrounding kills long exports silently (~30s budget, expiration handler does nothing useful)
- **Files:** `Coreo/Export/ExportEngine.swift:427-440`.
- **What's wrong (VERIFIED limitation; failure mode INFERRED):** `beginBackgroundTask` buys ~30s on modern iOS. The expiration handler just ends the task; the export session is left running as the app suspends — it will fail mid-write (AVFoundation interrupts) or stall, and the user returns to either a generic failure or a hung progress card. DESIGN.md promised background export for long videos; EDGE-CASES.md:71 admits ~30s.
- **Recommended change:** (1) In the expiration handler, call `exportSession.cancelExport()` and set a flag so the surfaced error reads "Export was interrupted when Coreo went to the background — keep the app open during export and try again." (2) Optionally pause/resume strategy: on `didEnterBackground` during export, warn proactively. True background export (e.g., `AVAssetExportSession` does not support background continuation without significant rearchitecture) should be marked out-of-scope for v1 and the design doc amended.
- **Blast radius:** performExport + a string; WorkspaceViewModel error display already exists.
- **Verification:** Manual on device: start a 3-min export, background for 60s, return; assert clean error alert, no hung overlay, no partial file.
- **Confidence:** High on the change being needed; Medium on exact failure presentation today.

---

## MEDIUM

### M1. "Trim to overlap" is dead: fields never written, never exported
- **Files:** `Coreo/Models/CoreoProject.swift:48-52` (fields), `Coreo/Workspace/TimelineView.swift:261-271` (read-only overlay). Grep confirms no writer anywhere; ExportEngine never reads them (EDGE-CASES.md:70 admits export ignores trim).
- **What's wrong (VERIFIED):** DESIGN.md sec. 5 specifies a one-tap "Trim to overlap" button. The model and a dimming overlay exist; the button and export application don't.
- **Recommended change:** (a) Workspace lens: add the button (sets `timelineTrimStartSeconds = overlapStartSeconds`, duration = `overlapEndSeconds - overlapStartSeconds`; undo = nil them). (b) Export lens: after building the composition (and BEFORE speed segments — define order: trim first, then speed times must be interpreted within trimmed window) apply `composition.removeTimeRange` for [end, duration] then [0, start-in-composition], or simpler: clamp each track's insert range during `buildComposition`. Document the chosen order in code; H5's TimeMapper must incorporate trim.
- **Blast radius:** ExportEngine.buildComposition/applySpeedSegments, TimelineView, WorkspaceViewModel.
- **Verification:** Export with trim [5,15] of a 30s timeline -> duration == 10s + bumper; first frame content == frame at t=5.
- **Confidence:** High.

### M2. Fixed 30fps export discards source frame rate; slow-mo segments judder
- **Files:** `Coreo/Export/ExportEngine.swift:44` (`exportFPS = 30`), `:310` (frameDuration).
- **What's wrong (VERIFIED choice, judder INFERRED):** 60fps phone footage exports at 30. A 0.25x speed segment on a 30fps source yields 7.5 unique fps — visibly steppy, and dance slow-mo is the headline use of speed segments. Preview (AVPlayer rate) shows the same source limit, but 60fps sources play slow-mo smoothly in preview and lose it in export.
- **Recommended change:** `exportFPS = min(60, max over tracks of nominalFrameRate)`, rounded to 30/60; force 60 when any segment rate < 1 and any source >= 60fps. Keep the bumper generator's fps in sync (pass it in; `EndBumperGenerator.fps` is independently hardcoded 30, EndBumperGenerator.swift:39).
- **Blast radius:** ExportEngine + EndBumperGenerator parameter.
- **Verification:** Export 60fps fixture: `AVAssetTrack.nominalFrameRate` of output == 60; eyeball slow-mo segment.
- **Confidence:** Medium-High.

### M3. Speed segments are not clamped to composition bounds
- **Files:** `Coreo/Export/ExportEngine.swift:230-259`.
- **What's wrong (INFERRED):** `segStart`/`segDuration` come straight from user data. A segment whose end exceeds `composition.duration` (float rounding at timeline end, or stale segments after videos were removed/re-synced — nothing prunes `speedSegments` when the timeline changes) passes an out-of-bounds range to `scaleTimeRange`, which raises an Objective-C exception (uncatchable from Swift) and crashes mid-export.
- **Recommended change:** Clamp: `let range = CMTimeRangeGetIntersection(requested, CMTimeRange(start: .zero, duration: composition.duration))`, skip if empty; also drop segments entirely outside. Additionally prune/validate `project.speedSegments` against the timeline on workspace entry.
- **Blast radius:** applySpeedSegments; small.
- **Verification:** Unit test via a tiny composition fixture: segment end = duration + 0.005s must not crash and must scale the clamped portion.
- **Confidence:** Medium (crash mode inferred), fix trivially safe.

### M4. Silent export when the selected audio source has no audio track
- **Files:** `Coreo/Export/ExportEngine.swift:206-216` (`if let sourceAudioTrack = ... first` silently skips); `WorkspaceViewModel.setAudioSource` (`:175-181`) lets the user pick any video, including no-audio imports (allowed per VideoAsset.swift:109-119).
- **What's wrong (VERIFIED):** If `audioSourceIndex` points at a no-audio video, the export completes with zero audio tracks and no warning — a dance video with no music.
- **Recommended change:** In ExportEngine, if the designated source yields no audio track, fall back to the highest-bitrate video that has one (reuse `selectBestAudioSource` logic — move it from ImportViewModel into CoreoProject or a shared helper) and proceed; if none has audio, proceed silent but surface a non-fatal notice. Also disable no-audio entries in the audio picker UI.
- **Blast radius:** ExportEngine + small UI change.
- **Verification:** Unit test on fallback selection; integration: project where audioSourceIndex video is silent -> output has audio from fallback.
- **Confidence:** High.

### M5. Orientation mapping ignores mirrored/flipped preferredTransforms
- **Files:** `Coreo/Export/PanelCompositor.swift:193-210`.
- **What's wrong (VERIFIED logic gap):** Only the 4 pure rotations are mapped; mirrored transforms (front-camera capture in some apps, edited/processed files) fall through to `.up`, rendering upside-down/mirrored content in export while `AVPlayerLayer` in preview honors the full transform.
- **Recommended change:** Either map all 8 `CGImagePropertyOrientation` cases (detect b/c sign combos with a==d==0, and a==+-1,d==-+1 flips), or drop the orientation enum entirely and apply the actual `preferredTransform` to the CIImage: `image.transformed(by: transform)` normalized back to origin — exact by construction.
- **Blast radius:** PanelCompositor only.
- **Verification:** Unit test `orientation(from:)` for the 8 canonical transforms; fixture video with mirrored transform.
- **Confidence:** Medium-High.

### M6. No explicit color management; HDR -> SDR uncontrolled
- **Files:** `Coreo/Export/PanelCompositor.swift:71` (CIContext default working space), `:79-85` (force 32BGRA), `:185` (render without colorspace); `ExportEngine.buildVideoComposition` sets no color properties; `EndBumperGenerator.swift:248` uses `CGColorSpaceCreateDeviceRGB()`.
- **What's wrong (VERIFIED absence; visual impact partly INFERRED):** Mixed BT.709/BT.601 sources and HDR (HLG/BT.2020) iPhone footage get whatever default conversion CoreVideo/CI applies when vending 32BGRA — HDR appears washed out (EDGE-CASES.md:43 admits no tone mapping); bumper colors are device-space, not sRGB, so the #0A0A0A background can mismatch the compositor's background between segments.
- **Recommended change:** (1) Set `videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2`, `.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2`, `.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2` for a deterministic SDR 709 pipeline. (2) Create the CIContext with `[.workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!]` (or sRGB) and pass an explicit colorspace to `render`. (3) Bumper: use sRGB colorspace. (4) Keep HDR tone-mapping as a documented v1 gap (matches Known Won't Fix) but the 709 tagging alone removes the bumper/panel background mismatch risk.
- **Blast radius:** PanelCompositor, ExportEngine, EndBumperGenerator.
- **Verification:** Export with SDR fixture; probe output color tags via `ffprobe`/AVAssetTrack formatDescriptions extensions == 709 triple; visual A/B of bumper-vs-panel background continuity.
- **Confidence:** Medium.

### M7. Disk-space pre-check is a fixed 500MB regardless of export size
- **Files:** `Coreo/Export/ExportEngine.swift:64,486-492`.
- **What's wrong (VERIFIED):** A 30-minute 1080p export can exceed 2-3GB; 500MB passes pre-flight and dies mid-encode with a generic failure. Also uses `.systemFreeSize` rather than `volumeAvailableCapacityForImportantUsage` (which reflects purgeable space the system will actually free).
- **Recommended change:** Estimate `expectedBytes = finalDurationSeconds * presetBitrate(resolution) / 8 * 1.5` (use H5 TimeMapper's mainContentDuration + bumper) and require that much via `URLResourceValues.volumeAvailableCapacityForImportantUsage` on the tmp volume; map `AVError.Code.diskFull` from the export failure to `ExportError.diskFull` so mid-flight failures also read nicely.
- **Blast radius:** checkDiskSpace + call site.
- **Verification:** Unit test the estimator; simulate by lowering threshold.
- **Confidence:** High.

### M8. sanitizeIndices silently zeroes syncOffsets — export would produce an unsynced video instead of failing
- **Files:** `Coreo/Models/CoreoProject.swift:100-102`; invoked at `ExportEngine.swift:62`.
- **What's wrong (VERIFIED):** On a count mismatch (the invariant EDGE-CASES.md:51 admits is unenforced), sync offsets are replaced with zeros and the export proceeds: all angles start simultaneously, i.e., visibly OUT of sync — the one thing the app exists to prevent. Silent wrong output is worse than an error.
- **Recommended change:** In the export path, treat mismatch as fatal: `throw ExportError.compositionFailed("Project sync data is inconsistent — re-sync your videos.")`. Keep the zero-fill behavior only for UI-survival paths if needed. Longer term: enforce `videos.count == syncOffsets.count` in a model invariant (didSet or builder).
- **Blast radius:** ExportEngine + CoreoProject; check other sanitize callers (ImportViewModel paths).
- **Verification:** Unit test: project with 3 videos / 2 offsets -> export throws, does not produce a file.
- **Confidence:** High.

### M9. No quality/preset knobs; design's "720p fast export" missing; H.264-only highest-quality preset
- **Files:** `Coreo/Export/ExportEngine.swift:442-445` (`AVAssetExportPresetHighestQuality`); `Coreo/Export/ExportSettings.swift` (aspect only).
- **What's wrong (VERIFIED):** DESIGN.md sec. 8 calls for 1080p default + 720p fast option. `ExportSettings` only changes aspect. `HighestQuality` preset picks bitrate independent of source quality — 540p sources upscaled into a 1080p canvas waste bitrate/file size; no HEVC option for ~40% smaller files on modern devices.
- **Recommended change:** Add `ExportQuality { standard1080, fast720, hevc1080 }` to ExportSettings; map to presets (`AVAssetExportPreset1920x1080`, `...1280x720`, `AVAssetExportPresetHEVC1920x1080`) and scale `renderSize` accordingly (layout math already parameterized). Default 1080 H.264 for compatibility.
- **Blast radius:** ExportSettings, ExportEngine, WorkspaceView picker.
- **Verification:** Export same project at both qualities; assert output dimensions and that 720 file is smaller; time both.
- **Confidence:** High.

### M10. Layout variants lack stacked options — portrait/square exports of 2-3 landscape videos waste most of the frame
- **Files:** `Coreo/Models/LayoutEngine.swift:61-76` (`case 2: [[2]]` only; 3 lacks `[1,1,1]`; 4 lacks `[1,3]/[3,1]`...).
- **What's wrong (VERIFIED):** With the portrait 1080x1920 export option (ExportSettings.swift:19-21), two 16:9 videos forced side-by-side occupy two skinny columns; vertically stacked (`[1,1]`) would more than double visible area. The variant search can't pick what isn't enumerated.
- **Recommended change:** Add `[1,1]` for 2, `[1,1,1]` and `[3]` for 3, `[1,1,2]`-style only if cheap — at minimum `[1,1]` and `[1,1,1]`. The existing scorer picks the best automatically. (Sanity-check the design table assumed landscape; portrait export is a Coreo addition, so this extends rather than contradicts design.)
- **Blast radius:** LayoutEngine + its tests (LayoutEngineTests exist — extend).
- **Verification:** Unit test: 2 videos AR 16/9, container 1080x1920 -> chosen config is [1,1] with higher visible area than [2].
- **Confidence:** High.

### M11. End bumper: icon missing, fps/dimension coupling, file leak on failure path, thread-safety of UIKit drawing
- **Files:** `Coreo/Export/EndBumperGenerator.swift:281-317` (text only — DESIGN.md sec. "End Bumper" wants app icon + "Coreo" text); `ExportEngine.swift:269-292` (`removeItem` at end of `appendEndBumper` is skipped if any earlier `try` throws -> tmp leak); `EndBumperGenerator.swift:90-114` (UIKit `NSString.draw` + `UIGraphicsPushContext` from a nonisolated async context — officially main-thread-preferred APIs; INFERRED low risk but cheap to harden); bumper fps hardcoded 30 independent of M2.
- **Recommended change:** Draw the app icon (load from asset catalog, 80pt-equivalent scaled by resolution) above the text; wrap bumper URL cleanup in `defer`; render text via CoreText (`CTLineDraw`) to avoid UIKit context APIs off-main; accept fps parameter.
- **Blast radius:** EndBumperGenerator + appendEndBumper.
- **Verification:** Visual check of generated bumper file; tmp-dir empty after a forced bumper-insert failure.
- **Confidence:** High (leak, icon), Medium (thread-safety).

### M12. Export pipeline has zero test coverage
- **Files:** `CoreoTests/UnitTests/` contains Annotation/AudioSync/Layout/Model/TimeFormatting tests only — nothing for ExportEngine, PanelCompositor, AnnotationCompositor, EndBumperGenerator, SpeedMap-to-composition math.
- **What's wrong (VERIFIED):** The most failure-prone subsystem (and the one this report finds 4 criticals in) is untested. Much of it is testable without rendering: speed-segment math, TimeMapper (H5), layout parity (H2), orientation mapping (M5), opacity keyframes, crop-rect space conversion (C2), disk estimator (M7).
- **Recommended change:** Add `ExportMathTests` (pure functions), `PanelGeometryTests`, and one slow integration test gated behind an env flag that exports a 2s synthetic composition and probes frames. Extract pure logic out of ExportEngine where needed to enable this (e.g., `applySpeedSegments` planning -> a pure `[CompositionEdit]` builder applied separately).
- **Blast radius:** Tests + light refactors.
- **Confidence:** High.

---

## LOW

### L1. Cosmetic WYSIWYG drift: corner radius, gap/background colors
- Preview panels: 4pt rounded corners (`VideoPanelView.swift:79`), panel bg #0F0F0F (`:78`), grid gap color 0.1/#1A1A1A (`VideoGridView.swift:26`). Export: square corners, single bg #0A0A0A (`PanelCompositor.swift:47-49`). Pick one set of tokens (DesignSystem.swift exists) and use in both; rounded corners in export = add a rounded-rect mask per panel in the compositor (cheap with CIImage clamp/blend or skip — decide deliberately). VERIFIED. Confidence high; severity low.

### L2. Dead/misleading code in export path
- `applyAnnotationOverlay` (`ExportEngine.swift:395-413`) unreachable; `PanelConfig.videoSize` unused (`PanelCompositor.swift:30`); `ExportProgressView.statusText` claims "Adding annotations..." at 35-45% (`ExportProgressView.swift:112-114`) — false today. Remove/repurpose alongside C1. VERIFIED.

### L3. Bumper temp file leaks if insertion throws
- `ExportEngine.swift:269-292`: `try? removeItem` only runs on success; use `defer`. (Also covered in M11.) VERIFIED.

### L4. Exported filename is UUID gibberish
- `ExportEngine.swift:423-424`. Share sheet/save-to-Files shows `coreo_export_8F3A....mp4`. Use sanitized `"\(project.name) — \(yyyyMMdd-HHmm).mp4"`; keep UUID suffix on collision. VERIFIED.

### L5. `cancelAllPendingVideoCompositionRequests` is a no-op
- `PanelCompositor.swift:88`. On session cancel, queued requests still render. Track in-flight requests (atomic flag + set) and `request.finishCancelledRequest()`. Minor latency/energy win on cancel; pairs with C4. VERIFIED.

### L6. Per-frame background CIImage allocation
- `PanelCompositor.swift:122-128`: background color image rebuilt every frame. Cache one `CIImage` per instruction (instructions are immutable). Micro-perf; the compositor is otherwise sound (single CIContext, GPU renderer, render-context pixel buffer pool). VERIFIED.

### L7. Sequential asset loading & main-actor composition build
- `ExportEngine.swift:51` (`@MainActor` for the whole pipeline) and `:142-150` (sequential `load`). Metadata loads are network-of-disk-cheap but 6 assets x several loads on the main actor can hitch UI for a beat. Move steps 1-5 off main (only progress callbacks hop to main), parallelize loads with a TaskGroup. VERIFIED structure; impact minor.

### L8. Progress fidelity
- Pre-export stage weights are guesses (load=5%, comp=10%...) and `exportSession.progress` (deprecated API family) is notoriously step-y with custom compositors; consider deriving the last-60% progress from `request.compositionTime / duration` inside PanelCompositor (it knows exactly how far it has rendered) routed via a callback. Also `exportSession.progress` polling at 10Hz keeps a MainActor task spinning — fine, but break the loop on `Task.isCancelled` only is insufficient post-C4. INFERRED smoothness; LOW.

### L9. `print` instead of structured logging on bumper failure
- `ExportEngine.swift:102`. Use `os.Logger` (rules: flag print in production). VERIFIED.

### L10. Global playback speed is (correctly) not exported — but undocumented
- Preview multiplies `playbackRate * segmentRate` (`WorkspaceViewModel.swift:525`); export uses only segment rates. Almost certainly intended (global speed = study tool), but a user at 0.5x global may expect the export slowed. Add a one-line doc comment + possibly UI copy on the export button. VERIFIED behavior; product decision needed.

### L11. No output metadata
- Export session sets no `metadata` (creation date, title=project name, software tag). Nice-to-have for camera-roll sorting. VERIFIED absence.

---

## Cross-lens notes (flagged for other survey agents)
- **Annotations invisible during normal playback in preview too:** `WorkspaceView.swift:50-55` only mounts `AnnotationOverlayView` when `isAnnotationMode` — contradicts DESIGN.md ("annotations fade in/out during normal playback"). Workspace lens should fix; export lens (C1) assumed fixed preview as the WYSIWYG reference.
- **Preview hold freezes forever** (see C3) — playback lens.
- **`finalizeProject(includeUnreliable:false)` reuses offsets relative to a possibly-removed reference and hardcodes referenceVideoIndex 0** (`ImportViewModel.swift:177-187`) — import/sync lens, but it feeds garbage sync offsets into export.
- **No schema versioning** (EDGE-CASES.md:64) — H4's model additions need a versioning story first; persistence lens.

## Prioritized TOP 10
1. C3 — Holds export as black gaps; implement freeze via one-frame insert + scaleTimeRange per track.
2. C2 — Apply cropRect in PanelCompositor (smart crop currently 100% lost in export).
3. C4 — Make cancel actually cancel (cancelExport + checkCancellation + guard success path).
4. H1 — Unify fit/fill semantics: crop-then-aspect-fill in BOTH preview and export via one shared geometry helper.
5. C1+H4+H5 — Re-enable annotations in export via in-compositor rendering, shared rasterizer, canvasSize model field, and a TimeMapper for speed/hold/bumper-aware timing.
6. H2 — Single layout source of truth: same variant + proportional gap for preview and export; preview the export aspect.
7. H3 — Persist pinch-zoom/pan as cropOverrides so manual framing exports.
8. H6 — Clamp insertTimeRange to actual track timeRanges (audio/video duration mismatch robustness).
9. M8 — Fail loudly on sync-offset mismatch instead of silently exporting unsynced video.
10. M1 — Implement and export trim-to-overlap; M2 (60fps export) and M9 (720p/HEVC quality knob) immediately behind.

## For JMT (needs a real device / product judgment)
- Whether export panels should have rounded corners + visible gaps like the preview (L1) — taste call, needs eyeballing on TV/phone.
- HDR footage: confirm how washed-out HLG iPhone clips actually look through the current pipeline before deciding if M6's 709 tagging is enough for v1 or tone mapping must be pulled forward.
- Global-speed-affects-export question (L10): product decision, 1-line answer.
- 30fps vs 60fps default export (M2): file size doubles for marginal benefit on fast phones — your call on default.
