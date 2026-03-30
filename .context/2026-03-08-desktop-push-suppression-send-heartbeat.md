## Context

The shipped desktop-active iOS push suppression used `messages.readMessages` as the desktop chat heartbeat. That makes suppression self-refresh as long as a foreground macOS client keeps auto-reading incoming messages, so an unattended desktop can suppress iOS pushes indefinitely.

## Plan

1. Stop treating read state as desktop activity for push suppression.
2. Refresh desktop chat activity from successful `messages.sendMessage` calls instead.
3. Increase the activity TTL so suppression still covers normal back-and-forth reply gaps.
4. Add focused regression tests around the tracker TTL and the send-message heartbeat source.

## Notes

- This remains an in-memory, single-instance optimization.
- The tradeoff is intentional: we prefer occasional extra iOS pushes over indefinite suppression when desktop is merely left open.
