# Nudge media type plan (2026-01-21)

## Goal
Move nudge detection to `mediaType = "nudge"` (no emoji-based detection), add InputMedia support, and keep DB changes minimal.

## Steps
- [x] Review current nudge handling in server encode/send paths, proto, and Apple send flows.
- [x] Update proto InputMedia to include nudge and regenerate protocol outputs.
- [x] Update server schema + send/encode logic to set/use `mediaType = "nudge"` and drop emoji detection (incl. notifications).
- [x] Update Apple send path (NudgeButton + SendMessageTransaction helper) to send InputMedia.nudge while keeping text.
- [x] Update/add tests to ensure only `mediaType = "nudge"` triggers nudge handling.

## Notes
- Keep message text as "👋" for UI display, but rely on mediaType for detection.
- Migration should only expand the existing mediaType enum/check.
