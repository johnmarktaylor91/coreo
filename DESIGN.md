# DESIGN.md — Coreo

## Product Overview

**Coreo** is a native iOS app for learning choreography from multi-angle video. Users import multiple video recordings of the same dance (filmed from different angles, typically in a class or rehearsal setting), and the app automatically synchronizes them via audio cross-correlation, displays them in an intelligent split-screen layout, and allows lightweight time-stamped annotation. The final output is a single exported video file — a complete multi-angle annotated visual reference of the choreography.

**Core philosophy:** Intelligent defaults that make the 80% case require zero configuration. Import → watch → export in two taps. Everything else is optional.

**Price:** $4.99 one-time purchase on the App Store. No subscriptions, no accounts, no server dependency. Entirely on-device.

**Target users:** Dancers learning choreography across all styles — salsa, bachata, K-pop dance covers (fancam sync), hip hop crews, ballroom, contemporary, Bollywood, West Coast Swing, Argentine tango, cheerleading, musical theater. The app is dance-focused in branding but technically works for any multi-angle video sync use case.

-----

## Technical Stack

- **Language:** Swift (latest stable)
- **UI Framework:** SwiftUI (primary), UIKit via `UIViewRepresentable` where needed (video playback layer, PencilKit integration)
- **Video/Audio:** AVFoundation (`AVPlayer`, `AVMutableComposition`, `AVVideoCompositionCoreAnimationTool`)
- **Audio Analysis:** Accelerate.framework (FFT-based cross-correlation for sync)
- **Person Detection:** Vision.framework (`VNDetectHumanRectanglesRequest` for smart crop)
- **Annotation Drawing:** PencilKit
- **Minimum iOS Version:** iOS 16.0
- **Architecture:** MVVM with SwiftUI
- **Persistence:** Local file system only. No CloudKit, no CoreData needed for MVP. Projects are self-contained directories.
- **No server component.** Everything runs on-device. No network calls, no analytics SDK, no accounts.

-----

## App Architecture

### Two-Screen Design

The entire app is two screens. That's it.

#### Screen 1: Import Screen (Drop Zone)

- Large, inviting open canvas with an "Add Videos" button prominently centered
- Supports both file picker (PHPickerViewController for photo library, UIDocumentPickerViewController for Files app) and drag-and-drop import
- As videos are added, they appear as thumbnails in a horizontal scrollable row with filenames and durations displayed
- Each thumbnail has a small "×" button to remove it
- Once 2+ videos are imported, a prominent "Sync" button appears (animated fade-in, pulse once to draw attention)
- Tapping "Sync" triggers the audio cross-correlation pipeline, shows a brief processing indicator, then transitions to Screen 2
- If audio sync fails for any video (correlation peak below confidence threshold), show a clear warning: "Couldn't match [filename] — audio may not overlap. Include anyway?" with Yes/No options
- If sync succeeds, transition to Screen 2 automatically

#### Screen 2: Workspace (Preview + Editor + Export)

This is the main screen. It is simultaneously the preview, editor, and export trigger. There are no separate "modes" or "steps."

**Default state on entry:**

- Synced videos playing in auto-generated split-screen layout, looping continuously
- Timeline scrub bar at the bottom with colored segments showing each video's temporal coverage
- Playback controls: play/pause (center), speed selector (small button showing current speed)
- Export button (top right, always visible)
- Edit tools (pencil icon, top right, collapsed by default)

**Always visible:**

- The video panels playing in sync
- The timeline scrub bar
- Play/pause
- Export button

**Discoverable on tap (Edit mode):**

- Annotation tools (pencil, text, arrow, color picker) with time-range controls
- Speed/hold segment tool
- Panel resize handles / divider drag
- Per-panel pinch-to-zoom
- Audio track selector

The workspace must feel like a viewer first and an editor second. A user who never touches the edit tools should have a complete, satisfying experience.

-----

## Core Features — Detailed Specifications

### 1. Video Import

**Supported formats:** Any format iOS can decode — .mp4, .mov, .m4v at minimum. Use `AVAsset` to verify playability on import.

**Import sources:**

- Photo Library (via PHPickerViewController)
- Files app (via UIDocumentPickerViewController)
- Drag and drop (if iPad)

**On import, immediately extract:**

- Video duration
- Video dimensions (width × height)
- Audio track metadata (sample rate, bitrate, channel count)
- Generate a thumbnail at the 25% timestamp for the import screen

**Limits:** Support 2–6 simultaneous video panels. Warn if >6 are imported ("Best results with 2–6 videos"). Do not hard-block, but UI may degrade.

### 2. Audio Synchronization

**Algorithm:**

1. Extract audio tracks from all imported videos as PCM float arrays (mono, downsample to 8kHz or 16kHz — sufficient for music correlation, much faster than full sample rate)
1. Designate one video as the "reference" (the longest one, or the one with highest audio bitrate)
1. For each other video, compute the cross-correlation with the reference audio using FFT-based correlation:
- FFT both signals (zero-pad to next power of 2 of combined length)
- Multiply FFT(reference) × conjugate(FFT(other))
- Inverse FFT
- Find the peak — its index gives the time offset in samples
- Convert sample offset to seconds
1. Store each video's offset relative to the reference timeline
1. Confidence check: if the peak correlation value (normalized) is below a threshold (e.g., 0.3), flag the video as potentially unmatched

**Implementation:** Use `Accelerate.framework` (`vDSP_fft_zrip` or similar) for all FFT operations. This must be fast — processing should take <2 seconds for typical 3-5 minute dance clips.

**Auto-select audio track:** Compare all imported videos' audio tracks. Auto-select the one with the highest bitrate as the audio source for the final export. Display a small, unobtrusive indicator: "Audio: [filename]" somewhere in the workspace. Tappable to switch to a different video's audio.

**Manual nudge fallback:** In the edit tools, provide a per-video fine-tune slider (±2 seconds, in 0.01s increments) for manual sync adjustment. This handles the <5% of cases where auto-sync is slightly off.

### 3. Smart Auto-Crop (Person Detection)

**Purpose:** Maximize useful content in each panel by cropping to the area of activity rather than showing the full wide-angle frame with wasted space.

**Algorithm:**

1. On sync completion, run `VNDetectHumanRectanglesRequest` on sampled frames (every 2-3 seconds) from each video
1. Compute the bounding box union across all sampled frames — this gives the "activity region" for that video
1. Pad the bounding box by 15% on all sides (clamped to frame bounds)
1. This padded region becomes the default crop/viewport for that panel

**Behavior:**

- Auto-crop is the default. The user sees the cropped view immediately on entering Screen 2.
- Users can override by pinch-to-zoom on any panel (this disables auto-crop for that panel and goes to manual framing)
- If person detection finds no humans (e.g., close-up of feet only), fall back to full frame — no crop

### 4. Auto Layout (Split Screen)

**Layout rules based on video count:**

|Count|Layout          |Description                                                                     |
|-----|----------------|--------------------------------------------------------------------------------|
|2    |Side by side    |Two panels, equal width, full height                                            |
|3    |1 top + 2 bottom|OR 2 top + 1 bottom (pick based on aspect ratios to maximize total visible area)|
|4    |2×2 grid        |Four equal panels                                                               |
|5    |2 top + 3 bottom|OR 3 top + 2 bottom                                                             |
|6    |2×3 grid        |OR 3×2 depending on aspect ratios                                               |

**Layout calculation logic:**

- For each possible layout variant, calculate total visible pixel area accounting for video aspect ratios and panel aspect ratios
- Pick the variant that maximizes total visible area (least letterboxing/pillarboxing)
- All panels should have a small gap (4-6pt) between them, with a dark background behind

**Fixed layout throughout playback.** The grid is determined by the total number of imported videos and does not change during playback. If a video hasn't started yet or has already ended, its panel shows black with a subtle label ("Starts in 0:04" or "Ended"). The other panels do NOT resize — the grid is static.

**Manual override:** Users can drag the dividers between panels to resize them. Pinch-to-zoom within any individual panel. These overrides persist for the session/project.

### 5. Unified Timeline

**This is the most important architectural component.**

All video panels are driven by a single shared timeline.

**Implementation:**

- One authoritative `CMTime` clock that all playback follows
- The timeline spans from the earliest start point to the latest end point across all synced videos
- Each `AVPlayer` instance has a known offset relative to this timeline
- On seek/scrub, all players seek to their respective offset positions simultaneously
- On play/pause, all players start/stop together
- Playback rate changes apply to all players simultaneously

**Timeline UI (scrub bar):**

- Horizontal bar at the bottom of the workspace
- Shows the full timeline duration
- Colored segments (one color per video) indicate each video's temporal coverage within the timeline
- A draggable playhead for scrubbing
- Current timestamp display
- "Trim to overlap" button: optionally crops the timeline to only the region where ALL videos have coverage (the intersection). One tap, undoable.
- Annotation markers: small colored dots or flags on the timeline indicating where annotations exist. Tapping a marker jumps the playhead to that annotation's start time. This gives the user a visual map of where their notes are.

### 6. Playback Speed & Hold

**Speed control:**

- Default: 1× playback, looping
- Global speed options: 0.25×, 0.5×, 0.75×, 1×, 1.5×, 2×
- Per-segment speed: user can select a range on the timeline and assign a different speed to that segment

**Hold (frame freeze):**

- User selects a point on the timeline and applies a "Hold" for a specified duration (1s, 2s, 3s, 5s, or custom)
- During the hold, all panels freeze on that frame for the specified duration, then playback resumes
- In the data model, a Hold is just a speed segment with rate = 0 and a duration
- Multiple holds can be placed on the timeline

**Data model for playback rate map:**

```
struct SpeedSegment {
    let timeRange: CMTimeRange    // range on the master timeline
    let rate: Float               // 0.0 = hold/freeze, 0.25-2.0 = speed
    let holdDuration: CMTime?     // only for rate == 0: how long to freeze
}
```

**UI for speed/hold:**

- Tap the speed icon in the edit toolbar
- Timeline enters "segment selection" mode
- Drag to select a range (or tap a point for a hold)
- Pop-up with speed options appears
- Applied segments are visualized on the timeline as colored overlays

### 7. Time-Stamped Annotations

**This is a core differentiating feature.** Annotations are time-aware — each annotation has a time range during which it is visible. This lets users place notes like "DON'T DROP YOUR FRAME" or arrows pointing to hand positions that only appear during the relevant part of the choreography, then disappear when they're no longer relevant.

**Tools available:**

1. **Freehand drawing** — via PencilKit. Finger or Apple Pencil. Multiple colors.
1. **Text labels** — tap to place, type text, draggable to reposition. Adjustable font size.
1. **Arrows** — tap start point, drag to end point. Directional arrow rendered. Color selectable.
1. **Eraser** — remove individual annotations

**Time range behavior:**

Every annotation has a `visibleTimeRange: CMTimeRange` that determines when it appears and disappears during playback.

**Default time range on creation:** When the user creates an annotation, its default visible range is a 3-second window centered on the current playhead position (1.5s before, 1.5s after, clamped to timeline bounds). This is a sensible default — most annotations reference a specific moment, and 3 seconds gives enough context.

**Adjusting time range:** Each annotation has small handles on the timeline (or a popover) that let the user drag the start and end of its visible range. The user can also make an annotation persistent (visible for the entire duration) by toggling a "Show always" option — this sets the range to the full timeline.

**Creation workflow:**

1. User enters annotation mode (taps pencil icon)
1. Video pauses automatically (so they can draw precisely on the frame they want)
1. User draws, places text, or adds an arrow
1. A small time range indicator appears on the timeline showing the annotation's 3-second default window
1. User can drag the handles to adjust, or tap "Show always" to make it persistent
1. User taps "Done" or exits annotation mode
1. Video resumes playback; the annotation fades in and out at its designated time range

**Fade behavior:** Annotations fade in over 0.2s at the start of their visible range and fade out over 0.2s at the end. This feels smooth rather than jarring.

**Multiple annotations:** Each annotation is independent. Multiple annotations can overlap in time. They are layered in creation order (newest on top). The timeline shows small colored markers for each annotation's position so the user can see at a glance where all their notes live.

**Editing existing annotations:**

- Tap on an annotation during its visible time to select it
- Selected annotation shows handles for repositioning, resize, and a delete button
- Time range can be adjusted via the timeline handles
- Double-tap text annotation to edit the text content

**Data model:**

```
struct TimedAnnotation {
    let id: UUID
    var visibleTimeRange: CMTimeRange     // when this annotation appears
    var isPersistent: Bool                // if true, visible for entire timeline
    var content: AnnotationContent        // what the annotation is
    var createdAt: Date
}

enum AnnotationContent {
    case drawing(PKDrawing)
    case text(TextAnnotation)
    case arrow(ArrowAnnotation)
}

struct TextAnnotation {
    var text: String
    var position: CGPoint                 // normalized 0-1
    var fontSize: CGFloat
    var color: Color
}

struct ArrowAnnotation {
    var start: CGPoint                    // normalized 0-1
    var end: CGPoint                      // normalized 0-1
    var color: Color
    var lineWidth: CGFloat
}
```

**Annotation layer rendering:**

- Annotations render on a transparent overlay above all video panels
- Annotations are per-project, not per-panel (they sit on top of the entire split-screen view)
- At any given playhead position, only annotations whose `visibleTimeRange` contains the current time are rendered
- Each visible annotation has its opacity modulated by the fade-in/fade-out at range boundaries
- In export, the annotation layer is composited on top of the video composition, with the same time-based visibility and fading baked in

**Color palette:** 5-6 high-visibility colors (white, red, yellow, cyan, green, orange) that show up against varied video content. Default: white.

**Export considerations for timed annotations:**

- During export composition, annotations must be rendered as time-varying `CALayer` animations (using `CABasicAnimation` for opacity keyed to each annotation's visible range)
- Each annotation becomes a sublayer with its opacity animated: 0 → 1 (fade in at range start), hold at 1, 1 → 0 (fade out at range end)
- PencilKit drawings are rasterized to `UIImage` and placed as `CALayer` contents
- Text and arrow annotations are rendered as `CATextLayer` and `CAShapeLayer` respectively

### 8. Export

**Output:** A single .mp4 file containing:

- All synced video panels composited into the split-screen layout
- The selected audio track
- Time-stamped annotation overlay baked in (with correct fade-in/fade-out timing)
- All speed/hold modifications applied
- 1-second branded end card: "Coreo" logo animation on solid background (the app icon with a simple fade-in)

**Export pipeline:**

1. Create an `AVMutableComposition` with video tracks for each panel
1. Create a custom `AVVideoComposition` that:
- Positions each video in its panel rectangle
- Applies the crop/zoom per panel
- Applies the speed/hold map to the timeline
1. Use `AVVideoCompositionCoreAnimationTool` to overlay the annotation layer:
- Build a `CALayer` tree with one sublayer per annotation
- Each sublayer has `CABasicAnimation` keyframes for opacity matching the annotation's visible time range
- PencilKit drawings → rasterized `UIImage` → `CALayer` with `contents`
- Text annotations → `CATextLayer`
- Arrow annotations → `CAShapeLayer`
1. Add the 1-second end bumper as an additional composition segment
1. Export via `AVAssetExportSession` with preset `AVAssetExportPreset1920x1080` (1080p default)
1. Show a progress bar during export (use `exportSession.progress` on a timer)
1. On completion, present the iOS share sheet so the user can save to camera roll, AirDrop, share to WhatsApp/Instagram/etc.

**Export resolution:** 1080p default. Offer 720p as a "fast export" option for longer videos.

-----

## Project Data Model

Each "project" is a self-contained unit:

```
struct CoreoProject {
    let id: UUID
    var name: String
    var createdAt: Date
    var videos: [VideoAsset]
    var referenceVideoIndex: Int          // which video is the sync reference
    var syncOffsets: [TimeInterval]        // per-video offset from reference
    var layoutOverrides: LayoutOverrides?  // user's manual panel sizing, if any
    var cropOverrides: [Int: CGRect]?      // per-panel manual crop, if any
    var speedSegments: [SpeedSegment]
    var annotations: [TimedAnnotation]     // time-stamped annotations
    var timelineTrimRange: CMTimeRange?    // if user used "trim to overlap"
    var audioSourceIndex: Int              // which video's audio to use
}

struct VideoAsset {
    let localURL: URL
    let duration: CMTime
    let dimensions: CGSize
    let audioBitrate: Int
    let audioSampleRate: Int
}

struct LayoutOverrides {
    var panelRects: [CGRect]              // normalized 0-1 coordinates
}

struct SpeedSegment {
    let timeRange: CMTimeRange
    let rate: Float                       // 0.0 = hold/freeze
    let holdDuration: CMTime?             // only for rate == 0
}

struct TimedAnnotation {
    let id: UUID
    var visibleTimeRange: CMTimeRange
    var isPersistent: Bool
    var content: AnnotationContent
    var createdAt: Date
}

enum AnnotationContent {
    case drawing(PKDrawing)
    case text(TextAnnotation)
    case arrow(ArrowAnnotation)
}

struct TextAnnotation {
    var text: String
    var position: CGPoint                 // normalized 0-1
    var fontSize: CGFloat
    var color: Color
}

struct ArrowAnnotation {
    var start: CGPoint
    var end: CGPoint
    var color: Color
    var lineWidth: CGFloat
}
```

**Persistence:** Save projects as JSON + associated video file references. Store in the app's Documents directory. Videos are referenced by URL (not copied, to save storage), with a warning if the source video is deleted/moved. PencilKit drawings are serialized via `PKDrawing`'s built-in `Data` encoding and stored alongside the project JSON.

-----

## UI/UX Specifications

### Visual Style

- **Dark mode default.** Dark backgrounds make video content pop.
- **Minimal chrome.** Controls should be unobtrusive and semi-transparent when not in use.
- **Accent color:** Warm coral/orange (#FF6B35 to #E83F3F gradient range) — matches the app icon and stands out against dark UI.
- **Typography:** System font (SF Pro). No custom fonts needed.
- **Animations:** Smooth, brief transitions. No gratuitous animation. The video content is the star.

### Import Screen (Screen 1) Specifics

- Background: Dark (#0A0A0A)
- Center icon: A subtle outline of the Coreo logo or a "+" icon, with text "Add Videos" below
- Import button style: Large, rounded rectangle, coral accent color
- Thumbnails row: Horizontal scroll, each thumbnail ~80pt wide with rounded corners
- Sync button: Full-width at bottom, coral gradient, appears with a smooth fade when 2+ videos are loaded
- Loading state during sync: Replace the Sync button with a progress indicator and "Syncing audio…" text

### Workspace (Screen 2) Specifics

- Video panels fill the available space above the timeline bar
- Panel gaps: 4pt, dark background (#1A1A1A) visible in gaps
- Timeline bar: ~80pt tall (slightly taller to accommodate annotation markers), dark semi-transparent background
  - Playhead: Thin vertical line, white, with a small circular grab handle
  - Video coverage indicators: Thin colored bars above the scrub area, one per video
  - Speed segment indicators: Colored overlays on the timeline where speed differs from 1×
  - Hold indicators: Small pause icon on the timeline at hold points
  - Annotation markers: Small colored dots below the scrub area indicating where annotations exist. Color matches the annotation's color. Tapping a marker jumps playhead to that annotation's start time.
- Control bar (above timeline): Play/Pause (center), Speed indicator (right of play), current time / total time (left)
- Top bar: Back arrow (left), project name (center), Edit tools icon + Export button (right)
- Edit tools panel: Slides down from top or up from bottom when activated. Contains annotation tools, speed/hold tool, audio source selector, manual sync nudge.

### Annotation Mode Specifics

- When user taps the pencil/annotation icon, annotation mode activates:
  - Video **pauses automatically** so the user can draw precisely on the desired frame
  - A floating toolbar appears with: pencil (freehand), text (T), arrow, eraser, color picker, "Done" button
  - The timeline remains visible and interactive — user can scrub to a different frame before annotating
  - Below the timeline (or as a popover), the time range control appears:
    - A mini range slider showing the current annotation's visible window on the timeline
    - Drag handles to adjust start/end
    - A "Show always" toggle to make the annotation persistent
    - The default range (3s centered on playhead) is pre-set
  - After placing an annotation, the user can immediately place another (stays in annotation mode)
  - Tapping "Done" exits annotation mode and resumes playback
- When NOT in annotation mode:
  - Annotations fade in and out at their designated times during normal playback
  - Annotation markers on the timeline are always visible so the user knows where notes exist
  - Tapping an annotation marker on the timeline jumps to that time and enters annotation mode for editing

### Gestures

- **Pinch on a panel:** Zoom in/out on that panel's video content
- **Drag on a divider:** Resize adjacent panels
- **Drag on playhead:** Scrub through timeline
- **Tap play/pause:** Toggle playback
- **Tap on panel (in annotation mode):** Place text or arrow start point
- **Draw on panel (in annotation mode):** Freehand PencilKit drawing
- **Tap annotation marker on timeline:** Jump to annotation time, enter edit mode for that annotation
- **Tap existing annotation (in annotation mode):** Select it for editing/repositioning/deleting

-----

## End Bumper (Export Branding)

- Duration: 1 second
- Background: Solid dark (#0A0A0A)
- Content: Coreo app icon (centered, small ~80pt) with "Coreo" text below in SF Pro Medium, white, 16pt
- Animation: Simple fade-in over 0.3s, hold, fade-out over 0.3s
- Audio: Silence during the bumper (do not extend the music)

-----

## Edge Cases & Error Handling

|Scenario                                        |Handling                                                                                |
|------------------------------------------------|----------------------------------------------------------------------------------------|
|Videos with no audio track                      |Warn user, allow manual placement on timeline with drag                                 |
|Very short overlap between videos               |Warn if overlap < 5 seconds, still attempt sync                                         |
|All videos same length & start                  |Perfect case, no issues                                                                 |
|Single video imported, user hits sync           |Inform "Add at least 2 videos to sync." Disable sync button for 1 video                 |
|Import fails (corrupt file)                     |Show error with filename, allow user to remove and continue                             |
|Export fails (disk full)                        |Show clear error, suggest freeing storage                                               |
|Very long videos (>30 min)                      |Warn that export may take a while, allow background export                              |
|Person detection finds no people                |Fall back to full frame (no crop), log for debugging                                    |
|User rotates device                             |Lock to portrait for phone, support both orientations on iPad                           |
|App backgrounded during export                  |Continue export in background (request background task time from iOS)                   |
|Annotation created at very start/end of timeline|Clamp the 3s default window to timeline bounds (don't extend before 0 or after end)     |
|Many overlapping annotations at same time       |Render all in creation order (newest on top), may look busy but that's the user's choice|
|PencilKit drawing serialization failure         |Catch error, warn user, save project without that drawing                               |

-----

## What Is NOT in MVP (v2+ Features)

Do not build these yet. They are documented for future reference:

- **Multiple projects** (v1 can support one project at a time; saving/loading multiple is v2)
- **Video recording directly in-app**
- **Cloud sync / sharing projects between devices**
- **Android version**
- **iPad-specific layouts** (iPad works but with the phone layout; iPad-optimized is v2)
- **AI-powered features** (auto beat detection, move segmentation, etc.)
- **Social features** (sharing within the app, community)
- **Localization** (ship English first; Spanish, Korean, Japanese are high-priority for v2)
- **Apple Pencil pressure sensitivity for annotations** (PencilKit handles this somewhat, but don't optimize for it)
- **Video trimming per-clip before sync** (users should trim in Photos first)
- **Per-panel annotations** (annotations that are confined to a single panel rather than overlaying the whole view)
- **Annotation templates/stickers** (pre-made shapes like "watch the feet" or "timing!" badges)

-----

## App Store Metadata (Reference)

**App Name:** Coreo

**Subtitle (30 chars max):** Learn choreography faster

**Keywords (100 chars):** choreography,dance,fancam,sync,multi-angle,salsa,kpop,bachata,ballet,practice,split-screen,video

**Category:** Photo & Video (primary), Entertainment (secondary)

**Description (draft):**
Drop your dance videos. Coreo syncs them automatically by matching the audio, arranges them in a smart split-screen layout, and lets you annotate with time-stamped drawings, arrows, and notes that appear exactly when you need them.

No timeline. No layers. No editing degree required. Just the tool dancers have been waiting for.

Works with any dance style — salsa, bachata, K-pop dance covers, hip hop, ballet, contemporary, ballroom, Bollywood, and more. Perfect for syncing fancams, class recordings, or rehearsal footage from different angles.

- Auto-sync via audio matching
- Smart split-screen layout for 2-6 videos
- Auto-crop to the dancer
- Time-stamped annotations — draw, write, and point at exactly the right moment
- Slow motion and frame hold for tricky sections
- Export one clean video file
- No account required. No subscription. Pay once, yours forever.
- 100% on-device. Your videos never leave your phone.

-----

## Build & Development Notes

- **IDE:** Xcode (required for iOS compilation and simulator)
- **Project type:** SwiftUI App (not Storyboard-based)
- **File structure:** Organize by feature, not by type:

  ```
  Coreo/
  ├── App/
  │   ├── CoreoApp.swift              # App entry point
  │   └── ContentView.swift           # Root navigation
  ├── Import/
  │   ├── ImportView.swift            # Screen 1
  │   ├── VideoThumbnailView.swift
  │   └── ImportViewModel.swift
  ├── Workspace/
  │   ├── WorkspaceView.swift         # Screen 2
  │   ├── VideoGridView.swift         # Split-screen panel layout
  │   ├── VideoPanelView.swift        # Individual panel
  │   ├── TimelineView.swift          # Scrub bar + segments + annotation markers
  │   ├── PlaybackControlsView.swift
  │   └── WorkspaceViewModel.swift
  ├── Sync/
  │   ├── AudioSyncEngine.swift       # FFT cross-correlation
  │   └── AudioExtractor.swift        # AVAsset → PCM float array
  ├── Crop/
  │   ├── PersonDetector.swift        # Vision framework integration
  │   └── SmartCropEngine.swift       # Bounding box computation
  ├── Annotations/
  │   ├── AnnotationOverlayView.swift # Renders visible annotations at current time
  │   ├── AnnotationToolbar.swift     # Floating tool palette
  │   ├── AnnotationTimeRangeControl.swift  # Mini timeline for annotation visibility range
  │   ├── TextAnnotationView.swift
  │   ├── ArrowAnnotationView.swift
  │   ├── AnnotationMarkerView.swift  # Timeline markers showing annotation positions
  │   └── AnnotationModel.swift       # TimedAnnotation and related types
  ├── Speed/
  │   ├── SpeedControlView.swift
  │   ├── SpeedSegmentModel.swift
  │   └── HoldMarkerView.swift
  ├── Export/
  │   ├── ExportEngine.swift          # AVMutableComposition pipeline
  │   ├── AnnotationCompositor.swift  # Builds CALayer tree with timed opacity animations
  │   ├── EndBumperGenerator.swift    # 1s branded card
  │   └── ExportProgressView.swift
  ├── Models/
  │   ├── CoreoProject.swift          # Main data model
  │   ├── VideoAsset.swift
  │   └── LayoutEngine.swift          # Auto-layout calculation
  ├── Utilities/
  │   ├── FFTHelper.swift             # Accelerate framework wrappers
  │   └── TimeFormatting.swift
  └── Resources/
      └── Assets.xcassets             # App icon, accent colors
  ```
- **Key dependency:** No external dependencies for MVP. Use only Apple frameworks: SwiftUI, AVFoundation, Accelerate, Vision, PencilKit. This keeps the build simple and the app lightweight.

-----

## Development Priority Order

Build in this order, test each component before moving on:

1. **Project scaffold** — SwiftUI app, two-screen navigation, dark theme
1. **Video import** — File picker, thumbnail generation, basic list UI
1. **Single video playback** — Get one AVPlayer rendering in a SwiftUI view
1. **Multi-video playback** — Multiple AVPlayers synced to one timeline clock
1. **Auto-layout** — Grid calculation and rendering for 2-6 panels
1. **Audio sync engine** — FFT cross-correlation, offset calculation
1. **Timeline UI** — Scrub bar, playhead, video coverage indicators
1. **Smart crop** — Vision person detection, auto-crop per panel
1. **Manual adjustments** — Panel resize, pinch-to-zoom, sync nudge slider
1. **Time-stamped annotations** — PencilKit overlay, text labels, arrows, time range per annotation, fade in/out, annotation markers on timeline, annotation mode (auto-pause, toolbar, time range control)
1. **Speed/hold** — Segment selection, rate map, hold markers
1. **Export** — AVMutableComposition pipeline, timed annotation compositor (CALayer tree with opacity animations), end bumper
1. **Polish** — Error handling, loading states, animations, edge cases
1. **App Store prep** — Icon, screenshots, metadata, TestFlight build
