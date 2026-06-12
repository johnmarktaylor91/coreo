# Test baseline (main @ 9537ec3, 2026-06-11 ~19:50 EDT)

Full suite: 76 tests, 5 failures, destination iPhone 17 Pro / iOS 26.5 sim.
(Note: test target did not COMPILE before 9537ec3 -- suite had never run.)

Baseline-RED (known failures, survey-predicted):
- AudioSyncTests.test_findOffset_knownShift_recoversLag        (inverted vs impl; Wave 1 fixes TEST per D1)
- AudioSyncTests.test_findOffset_negativeShift_returnsNegativeLag (same)
- LayoutEngineTests.testInvalidVideoCountReturnsEmpty           (6-video bug family; Wave 3)
- LayoutEngineTests.testNoRectsOverlapForAnyCount               (same)
- LayoutEngineTests.testSixVideoLayoutReturnsCorrectCount       (same)

Everything else (71 tests) baseline-GREEN -- regressions not acceptable.
