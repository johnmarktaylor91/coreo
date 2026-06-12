# Coreo Architectural Decisions

<!-- Format: ## [DATE] Decision Title
Context: why this came up
Decision: what was decided
Rationale: why
Alternatives considered: what else was on the table -->

## Full-scope improve run (2026-06-11) -- pinned decisions D1-D10
See .project-context/improve/PLAN.md for the full list. Highlights: D1 FFT
convention locked by test; D2 holds = freeze-frame (live timer + export
scaleTimeRange); D3 host-time master clock, no reference-player anchor; D4
export WYSIWYG = aspect-FIT + same LayoutEngine + crop applied; D5 UUID-keyed
per-video model + ProjectStore autosave; D6 iOS 17 target (JMT-reversible);
D7 audio session activates on play only; D9 reference-angle audio + per-panel
mute; D10 TimeMapper is the single time-math source of truth.
