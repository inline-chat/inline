## Scope

This follow-up is intentionally separate from the current transport telemetry and `NWPathMonitor` hardening pass.

The remaining work is:

1. simplify the retry state machine
2. run a Georges-focused validation pass with the new telemetry and decide the next solid fix

## Part 3: Retry State Machine Simplification

### Goals

- make retry ownership unambiguous
- prevent multiple subsystems from racing to reconnect
- keep recovery reliable under lifecycle changes, path changes, ping failures, and delegate callbacks

### Current problems

- reconnect scheduling is spread across:
  - `ensureConnected()`
  - ping failure handling
  - connection timeout handling
  - `didClose`
  - `didCompleteWithError`
  - `NWPathMonitor` callbacks
- delivery pause/resume depends on transport recovery plus later protocol `connectionOpen`
- different failure sources use slightly different disconnect paths

### Proposed shape

- use one explicit transport state enum with these stages:
  - `idle`
  - `connectingTransport`
  - `awaitingProtocolOpen`
  - `connected`
  - `backingOff`
  - `stopped`
- route every failure through one `fail(...)` path
- let only one reconnect controller schedule the next attempt
- make path monitor advisory only
- keep ping, receive, and delegate callbacks as inputs into that one controller, not peer reconnect owners

### Implementation steps

1. introduce a transport session token / attempt id and store it in all failure breadcrumbs and captures
2. split websocket-open from protocol-open in the state model
3. collapse reconnect scheduling into one helper that owns:
   - attempt count
   - backoff
   - jitter
   - foreground fast path
4. remove reconnect decisions from scattered call sites so they only call `fail(...)`
5. make message delivery react to explicit protocol state, not implicit transport recovery

### Validation

- foreground/background bounce
- wifi off/on
- router flap while app stays foregrounded
- long-lived idle connection for > 10 minutes
- receive failure followed by recovery
- ping failure followed by recovery

## Part 4: Georges Follow-Up

### Leading hypothesis

The strongest current hypothesis is periodic websocket teardown driven by session configuration or delegate lifecycle, not just generic network loss.

The old Sentry pattern showed roughly 5-minute repeated reconnects for Georges on macOS build `3880`, which matched the previous `timeoutIntervalForResource = 300`.

### What to check in the next build

- whether the 5-minute `didComplete` cadence disappears after removing the short resource timeout
- whether failures now cluster under:
  - `ws_origin=did_complete`
  - `ws_origin=did_close`
  - `ws_origin=receive`
  - `ws_origin=ping`
  - `ws_origin=connect_timeout`
- whether the failures happen:
  - before `connection_init_sent`
  - after `connection_init_sent`
  - after `connection_open`
- whether Georges still shows repeated app lifecycle breadcrumbs near the failures
- whether abnormal close codes appear once `101` noise is removed

### Next Georges-specific fixes if the hypothesis holds

- if `did_complete` still happens on a regular cadence:
  - inspect URLSession websocket configuration and delegate behavior further
- if failures move to `did_close` with abnormal close codes:
  - inspect server/proxy close reasons and close-code handling
- if failures move to `receive` / POSIX 53 or 57:
  - harden stale-task and cleanup sequencing around receive loop teardown
- if failures stall between transport open and protocol open:
  - add protocol-open timeout / auth retry logic

### Success criteria

- no more issue spam grouped around benign `101` metadata
- Georges sessions are attributable to one dominant failure stage
- enough structured context exists to choose the next fix based on evidence instead of inference
