# Coreo Manual Testing Guide

How to test Coreo as a human. Automated tests (116 unit tests, lint, format) catch
logic regressions; they cannot tell you whether the app feels right, whether sync
sounds right, whether export looks right, or whether a first-time user understands
the screen. That is your job. This doc is the playbook.

Grounded in the app as of 2026-06-12 (post full-scope improvement run, commit
fe5e000). If features change materially, regenerate this doc.

---

## 1. Principles (read once, then they're habits)

1. **You are testing the experience, not the code.** Latency, confusion, jank,
   trust. If you have to think "is that right?", that's a finding.
2. **Write down everything that feels off, immediately.** Don't rationalize
   ("probably fine", "maybe I tapped wrong"). Vague unease is data -- it's how
   real users feel bugs before they can name them. Capture first, judge later.
3. **One note per observation.** What you did, what you expected, what happened.
   A screenshot or screen recording beats three paragraphs.
4. **Reproduce before you trust it.** Saw something weird? Try the exact steps
   again. "Happened twice" is a bug report; "happened once" is a watch-item.
   Both are worth noting -- just label them.
5. **Test the edges, not just the middle.** Shortest clip, longest clip, 2 videos,
   6 videos, quiet audio, no audio, portrait + landscape mixed. Bugs live at
   boundaries.
6. **Fresh eyes beat tired eyes.** A 20-minute focused session finds more than a
   2-hour grind. Screenshot anything visual and look again the next day cold.
7. **Alternate free play and scripts.** Exploratory sessions (no checklist, just
   use it) find surprises; scripted passes (sections below) find gaps. You need
   both.
8. **Triage by severity as you go:** crash / data loss > wrong output (bad sync,
   wrong export) > confusing UX > ugly. Don't let polish notes bury a crash.
9. **When hunting a specific bug, change one variable at a time.** Same clips,
   same steps, vary only the thing you suspect.
10. **The demo test is the north star.** If you can hand the phone to a dancer
    friend and they get from "two videos" to "watching synced playback" without
    your help, the core works. Everything else is refinement.

---

## 2. Setup

### Test footage library (build this once, reuse forever)

Record or collect a small permanent set of clips. Suggested shoot: put a phone
speaker playing music in a room, film the same 30-60s from different positions
with whatever devices you have. You want:

- **The golden set:** 3 angles of the same dance/music moment, clear audio,
  60-90s, same orientation. This is your everyday test input.
- **Offset starts:** same scene but start each recording at a different time
  (one 10-30s late). Exercises sync offsets and late-join playback.
- **Mixed orientation/resolution:** at least one portrait + one landscape of the
  same moment; one 4K and one 1080p if possible. Exercises layout + crop +
  annotation coordinate mapping.
- **Audio edge cases:** one clip with very quiet/distant audio; one with NO audio
  track (record muted or strip audio). Sync should degrade gracefully, not abort.
- **Duration edges:** one very short clip (<5s) and one long one (3-5+ min).
- **Crop stressors:** full-body dancer moving across frame; two people; a clip
  with no people at all.
- **Count edges:** enough material to load 2 videos and 6 videos.

Keep these in a dedicated Photos album ("Coreo Test") so import is fast.

### Device + environment

- **Real device > simulator** for everything in this doc. Feel, haptics, thermals,
  audio routing, and camera footage only exist on hardware.
- **Test fresh-install state regularly:** delete the app, reinstall, launch. The
  first-run path (permissions, empty states, onboarding instincts) only exists
  on a clean install.
- **Turn on screen recording** (Control Center) for exploratory sessions. A bug
  you can scrub back to is half-diagnosed.
- Occasionally test in hostile conditions: Low Power Mode, low storage, low
  battery, AirPods connected, Do Not Disturb off (so calls can interrupt).

### Filing findings

- Quick capture: screenshot / screen-record, iMessage it to yourself with a
  one-line note (lands where CC can read it), or just batch notes and send.
- Per finding: **steps -> expected -> actual -> severity**. One line each is fine.
- CC triages findings into the fix queue and dispatches fix waves. You never need
  to maintain the bug list yourself.

---

## 3. The Golden Path (smoke test -- run after every code change)

This is the demo flow. It must always work, end to end, no exceptions. ~5 min.

1. Launch app (warm or cold).
2. Import the 3-angle golden set from Photos.
3. Auto-sync runs; watch progress; land in Workspace.
4. Press play. Check with your ears + eyes: beats and motion aligned across all
   panels? Let it run 60s -- still aligned?
5. Scrub somewhere, play again. Still aligned.
6. Add one drawn annotation and one text annotation at a specific beat; scrub
   across them; confirm they fade in/out at the right moments.
7. Set one segment to 0.5x speed; add one hold; play through both.
8. Export. Watch progress. Play the resulting .mp4 in Photos:
   - layout matches preview (panels, gaps, letterboxing)
   - annotations appear at the same moments, looking the same
   - hold is a freeze-frame (not a black gap), speed change is right
   - audio is the reference angle's audio, in sync
9. Force-quit the app, relaunch: project is still there, edits intact.

Any step failing = highest-priority finding. Note the step number.

---

## 4. Feature Passes (pick 1-2 sections per session, go deep)

### 4.1 Import

Try:
- Photos picker and the Files (document) picker.
- 2 videos, 6 videos. Then try to add a 7th (cap should refuse gracefully).
  Try starting with 1 (should not let you proceed to sync).
- Import the same video twice.
- Cancel mid-pick; cancel mid-import (progress should be cancellable and the
  app should land in a sane state).
- Deny photo permission (Settings -> Coreo), then try to import. Re-grant.
- Import while in Low Power Mode; import the 4K clips.

Watch for: thumbnails correct and right-side-up; per-item errors named clearly
with a retry that works; progress that moves and finishes; haptic feedback; no
frozen UI during import (it runs in parallel -- screen should stay responsive).

### 4.2 Sync

Try:
- Golden set (clear audio): sync should land within a frame or two. Verify by
  ear (claps/beats) and by eye (a sharp motion visible from 2+ angles).
- Offset-start set: the late clip should align correctly and join playback
  partway through the timeline.
- Quiet-audio clip in the mix; the no-audio clip in the mix (it should be
  flagged/skipped per-clip, not kill the whole sync).
- Cancel sync mid-run. Re-run it. Re-sync from the Workspace (back-nav and
  re-sync are always available).
- Manual nudge: deliberately judge a panel slightly off and use the +/- frame
  nudge buttons. Can you dial it in? Does the nudge persist through pause/play
  and scrubbing?

Watch for: how it FAILS matters most. Bad-input sync should produce a clear,
honest message and a path forward, never a silent wrong result or a hang.
Progress should be determinate and cancellable.

### 4.3 Layout + smart crop

Try:
- Every count: 2, 3, 4, 5, 6 panels. Rotate through which clips.
- Mixed portrait + landscape set.
- Crop stressors: full-body dancer (feet and head should stay in frame --
  this was specifically fixed; verify on real footage), two people, no people.

Watch for: dancers framed sensibly (the crop should follow the person, not cut
feet); no panel absurdly letterboxed when a smarter crop exists; layout stable
(panels shouldn't jump around mid-session); pinch zoom + double-tap reset feel.

### 4.4 Playback (the heart -- spend the most time here)

Try:
- Play/pause rapidly. Scrub fast, scrub slow, scrub to 0:00 and to the very end.
- Long-run drift check: play 3+ continuous minutes. Are panels still in sync at
  the end? (There is active drift correction; it should be invisible.)
- Late-start clips: with the offset set loaded, scrub before a clip's start --
  its panel should show its pre-roll state, then join in sync.
- Frame-step buttons: step forward/back at a sharp motion; all panels should
  step together.
- Mirror mode on one panel (note: preview-only by design; export won't mirror).
- Audio: mute/unmute panels; default should be reference-angle audio only.
- Interruptions: receive a phone call mid-play; trigger Siri; let an alarm fire.
  Playback should pause/resume sanely.
- Routes: connect/disconnect AirPods mid-play.
- Background music: have Spotify/Music playing, then open Coreo -- music should
  NOT die until you actually press play in Coreo.
- Background the app mid-play, return. Rotate the device. Force-quit mid-play.

Watch for: tap-to-play latency (should feel instant); scrub responsiveness (no
lag storm when dragging); panels visibly out of sync at ANY moment; audio
glitches/pops on seek; stutter on 6-panel playback (note device + clip specs).

### 4.5 Speed + holds

Try:
- 0.25x / 0.5x on a segment; multiple segments with different speeds; segment
  boundaries mid-move.
- Holds: place one, play through it live (should freeze, then resume in sync);
  scrub across it; place a hold inside a slowed segment.
- Edit/delete segments and holds; do annotations near them still appear at the
  right MOMENT (not the right second-number)?

Watch for: audio behavior at slow speeds; sync after resuming from a hold; the
timeline clearly showing where speed/holds apply.

### 4.6 Annotations

Try:
- Each tool: pencil drawing, text, arrow. On different panels and positions.
- Set time ranges; set show-always; scrub across the fade-in/out boundaries
  slowly -- fades should be smooth and correctly timed.
- Annotate on the mixed-resolution project: does the drawing land exactly where
  you drew it on every panel (no offset/scale errors in letterboxed panels)?
- Annotate inside a slowed segment and across a hold.
- Edit, move, delete annotations. Many annotations (10+) on one project.
- **Parity check (important):** screenshot a frame with annotations in preview,
  export, screenshot the same frame in the .mp4, compare side by side. Fonts,
  stroke weight, arrowheads, fade level, position -- should be identical (they
  share one rasterizer now; verify it).

Watch for: drawing latency with Apple Pencil/finger; annotations appearing at
the wrong time after speed changes (they're warped through the time mapper --
this is exactly the kind of math that needs human eyes).

### 4.7 Export

Try:
- Golden path export (above), then: export with 6 panels; with mixed
  orientations; a long project (5+ min) -- note duration and whether the phone
  gets hot; cancel mid-export (no share sheet should appear, no half-file in
  Photos); immediately re-export.
- Export with everything stacked: speeds + holds + annotations + crops + bumper.
- Low-storage behavior if you can stage it (it preflights disk space -- the
  error should be clear, early, and not corrupt anything).

Watch for: **WYSIWYG is the whole contract.** Compare exported .mp4 against
preview at 3-4 moments: layout, gaps, letterboxing, crop framing, annotation
timing/looks, hold freezes, audio sync. Any visible difference is a finding.
Also: export time feels proportional? Progress honest (no 99%-hang)? Bumper
correct and annotation-free?

### 4.8 Persistence + projects

Try:
- Force-quit at every stage: mid-import, post-sync, mid-annotation-edit,
  mid-export. Relaunch each time. What survived? (Autosave is debounced --
  losing the last ~1s is acceptable; losing the project is not.)
- Continue vs new-project choice on launch.
- Delete a source video from Photos AFTER importing it; relaunch. (Media is
  copied into the app, so the project should be fine. The missing-media
  recovery flow currently only offers remove, not re-pick -- known limitation.)
- Build up 2-3 projects over days; switch between them.

Watch for: silent data loss of any kind -- the unforgivable bug for a paid,
no-cloud app. Anything lost across a relaunch gets reported with exact steps.

### 4.9 System + accessibility

Try:
- VoiceOver on (Settings -> Accessibility): can you navigate import and the
  workspace timeline? Are controls labeled sensibly?
- Dynamic Type at a large size: anything truncated/overlapping?
- Reduce Motion on: animations should simplify, not break.
- Dark/light mode if applicable; rotation everywhere; iPad if you ever target it.

---

## 5. The Feel Pass (judgment only you can make)

No checklist logic here -- this is the aesthetics/UX holdout that explicitly
needs your taste. Questions to hold while using it:

- **First-run:** on a fresh install, is the next action obvious at every screen
  with zero instructions? Where did you hesitate, even for a second?
- **Latency budget:** every tap should acknowledge within ~100ms (highlight,
  haptic, motion). Anything that feels dead-then-jumps, note it.
- **Waiting:** sync and export are the two long waits. Do you trust the
  progress? Could you tell the difference between "working" and "hung"?
- **Error voice:** when it fails, does the message say what happened AND what to
  do next, in human words?
- **Gesture conflicts:** does scrubbing ever fight panning/zooming/drawing?
- **Visual rhythm:** spacing, alignment, type hierarchy (UI-POLISH.md has the
  intended token system). Screenshot key screens; review them cold tomorrow.
- **Haptics/sound:** helpful or noisy?
- **The 60-second demo:** narrate the app aloud to an imaginary dancer friend
  while driving it. Every place you say "oh wait" or "ignore that" is a finding.

---

## 6. Session Workflow (the cadence)

Three session types; rotate them:

| Type | When | How |
|------|------|-----|
| **Smoke** (golden path, sec. 3) | After every code change wave | ~5 min, scripted, must be 100% green |
| **Feature pass** (sec. 4) | 1-2 sections per sitting | ~20-30 min, scripted, go deep on edges |
| **Free play** (sec. 5 mindset) | Whenever, ideally rested | ~20 min, screen recording on, no checklist, just use it like a dancer would |

Rules of thumb:
- Timebox to ~30 min; fatigue makes you blind to friction.
- End every session by sending findings (even "nothing found, tested X and Y" --
  that's coverage data).
- After a fix wave lands, re-test the EXACT steps of the bugs it claims to fix,
  then run the smoke test for regressions.
- Before any release: full pass of every section in 4, on a real device, on a
  fresh install, with the full footage library.

---

## 7. One-Page Smoke Checklist (copy/paste per release candidate)

```
[ ] Fresh install, first launch clean
[ ] Import 3-angle golden set (Photos)
[ ] Import 6 videos; 7th refused; 1 video can't proceed
[ ] Auto-sync correct by ear + eye
[ ] No-audio clip handled gracefully
[ ] Play 3 min continuous -- no drift
[ ] Scrub to 0:00, to end, rapid scrubbing -- responsive, in sync
[ ] Frame-step works across all panels
[ ] Phone call interruption -> sane resume
[ ] Background music survives app open (dies only on play)
[ ] Annotation: draw/text/arrow, fades timed right
[ ] Speed 0.5x segment + hold play correctly live
[ ] Export completes; WYSIWYG vs preview (layout/annotations/holds/audio)
[ ] Cancel export -> no share sheet, no junk file
[ ] Force-quit + relaunch -> project intact
[ ] VoiceOver quick pass; Dynamic Type large; Reduce Motion
[ ] Phone temperature reasonable after long export
```
