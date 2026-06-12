# Tabled for JMT -- needs your eyes or your call

## Needs on-device review (after this run lands)
- Overall aesthetics pass: colors, spacing, animation feel, dark mode. Each survey
  report has a short "For JMT" section; collected pointers:
  - reports/ui-ux-responsiveness.md -- device-verify list + 9 taste proposals ranked
  - reports/performance-efficiency.md -- scrub feel / playback smoothness on device
  - reports/export-pipeline.md -- export quality knobs (bitrate/preset) eyeball check
- Annotation rendering fidelity preview-vs-export after Wave 5 (side-by-side eyeball).
- Smart-crop quality on real dance footage (Vision upperBodyOnly was cropping feet;
  changed to full-body -- verify it frames dancers well).

## Decisions I made that you can reverse
- Deployment target raised iOS 16 -> 17 (unlocks @Observable; app unreleased).
- Export uses aspect-FIT (letterbox) to match preview, not FILL.
- Export audio = reference angle's audio (silence fallback). Per-angle audio
  selection UI is implemented as simple mute toggles; richer mixing UX = your call.
- Auto-navigate to Workspace after sync kept, but now cancellable with progress.

## Deferred features (specs exist in reports, not implemented this run)
- Count-in (3-2-1) before playback; A-B loop region; scrub snapping to annotations.
  (ui-ux report ranks these; say the word and they're a small follow-up wave.)
- Manual sync fine-nudge UI shipped basic (+/- frame buttons); waveform-overlay
  alignment view would be the deluxe version.

## Untouched per your standing rules
- App Store / signing / provisioning / StoreKit / IAP.
