# Grid transcription worker

A separate Node process captures authorized LiveKit microphone tracks, segments each speaker's audio with Silero VAD, and posts finalized turns through the API's ordinary Grid transcription thread. The Bun API does not import the native RTC runtime. The feature remains gated; this package does not activate capture or change infrastructure by itself.

The internal `meeting` preset selects Soniox `stt-rt-v5` at signed16LE mono 16 kHz. `standard` selects OpenAI `gpt-transcribe` at signed16LE mono 24 kHz. Languages are automatic; translation and provider diarization are disabled. LiveKit microphone identity/SID joined with the API membership manifest supplies the speaker. There is no public model selector or provisional transcript feed. The meeting default is a product-fit choice pending real account/audio qualification, not a measured accuracy claim.

## Runtime boundaries

- `daemon.ts` advertises configured-provider availability, claims one room with a boot-unique worker ID, and renews its 15-second authority every second from monotonic request start. Availability heartbeats remain every five seconds. Fixed capture expiry is capped at two hours. A delayed response cannot grant a fresh lease or resurrect an expired owner. In-flight and delivery-unknown claims are reconciled on shutdown using the same boot identity; stop-only recovery cannot allocate RTC.
- `supervisor.ts` and the independent `watchdog.ts` own one native room child. Parent and child each send monotonic heartbeats. A stalled/disconnected parent, stalled child, expired lease, or failed startup closes admissions and escalates TERM to KILL. A child `stopped` message does not prove transport containment: the watchdog must observe actual OS exit, and the API must acknowledge that receipt before another claim. Known exit receipts retry on the existing heartbeat cadence after API recovery. Unknown native exit keeps the slot fenced.
- `room-worker.ts` registers callbacks before connecting with `autoSubscribe:false`, then sweeps existing publications. Only exact current API membership, participant object, microphone source, audio kind, publication object, track object and SID are eligible. Every queue write and captured PCM send rechecks them. Muted/departed/replaced tracks stop intake immediately. Retiring tracks remain bounded; a ninth owned microphone ends capture visibly rather than silently dropping a speaker. Native readers are cancelled and their locks released.
- `track-worker.ts` owns each speaker's serial VAD/admission/commit order. Admission happens before that turn's PCM reaches a provider. Native readers copy promptly into a two-second queue; they never await inference or network work. Queue overflow, seven-second stuck processing, provider failure, or unresolved-final timeout ends capture. The owner discards late admission/connect/inference results after stopping.
- `silero.ts` verifies the vendored official model SHA256 before single-thread CPU inference. Each track has its own recurrent state; 24 kHz is resampled to 16 kHz for VAD. `segmenter.ts` retains 300 ms preroll, ends after 550 ms silence (or 200 ms silence after six seconds), and bounds continuous speech to ten seconds at the production 20 ms frame size. A finite 200 ms zero tail precedes manual provider finalization. This boundary quality still needs real multilingual meeting qualification.
- `socket.ts` bounds provider/event buffers, verifies OpenAI's effective configuration before audio, and emits only finalized local turns. Empty completions still retire their admissions; the API suppresses empty message rows. There are at most two pending turns, a five-second final deadline, and 32 KiB UTF8 text per turn. Sockets rotate at drained boundaries before nine minutes or 900 turns; a rollover with undrained work interrupts capture rather than guessing/replaying. Decoders retain at most 1,024 identifiers per socket and fail closed on overflow.

Manual Stop closes new API admission immediately. The daemon observes Stop on its next active-run renewal (normally within one second), then its child synchronously closes PCM intake. An already-admitted turn can include audio collected during that notification delay; this is not a guarantee of pre-button audio only. Completion is accepted only within the API's fixed five-second deadline from the Stop request, and the UI stays Stopping until actual native exit. Ordinary voice leave may finish an already-admitted turn with its immutable speaker attribution. Destructive Space/history/destination invalidation or lost run authority discards immediately. Provider or native failure requires a fresh explicit Start; there is no automatic capture takeover, transcript fallback, or raw-audio persistence.

## Build and environment

Exact native dependencies are `@livekit/rtc-node` 1.1.0 (FFI 0.12.73) and `onnxruntime-node` 1.24.3. The model is copied into `dist` at build time with its license notice; no runtime model download is needed. The Dockerfile uses Node 24 Bookworm/glibc and the committed workspace lock. Linux ARM64 native packages exist; actual deployment-host import, resampling, microphone and shutdown behavior still require qualification. Alpine/musl is not supported by this plan.

Set only these named values through the deployment secret/config consumer; the worker does not load environment files or print credentials:

| Variable | Meaning |
| --- | --- |
| `GRID_TRANSCRIPTION_API_URL` | API HTTPS origin; loopback HTTP is allowed for controlled labs. URL path prefixes are rejected. |
| `GRID_TRANSCRIPTION_WORKER_SECRET` | Shared worker-control bearer secret, matching the API. |
| `GRID_TRANSCRIPTION_MODEL` | Internal `meeting` default or `standard`; must match API configuration. |
| `GRID_TRANSCRIPTION_WORKER_ID` | Optional 1–40 character boot-label (`a-z`, `A-Z`, digits, `_`, `-`); a fresh UUID is always appended. |
| `SONIOX_API_KEY` | Required to advertise readiness for `meeting`. |
| `OPENAI_API_KEY` | Required to advertise readiness for `standard`. |

A missing selected key advertises `ready:false` and never claims work. Readiness validates runtime/model/key presence; it does not establish paid account access, provider authentication, quota or model quality. Provider keys remain in the worker, passed to its native child over IPC rather than command-line arguments or inherited environment. Child stdout/stderr are suppressed; daemon logs contain only coarse availability state.

The worker calls `POST /_internal/grid-transcription/{heartbeat,claim,renew,admit,final,stopped}`. Heartbeat/claim use the shared secret; remaining calls use the run token. A normal claim supplies LiveKit credentials and the full membership manifest. A stop-only recovery claim supplies just run ID, epoch and token. Renewals fully replace the membership manifest and explicitly distinguish an allowed manual flush from destructive stopping. Admission returns the immutable segment ID; final persistence is idempotent for that ID. The API independently checks current Space, destination, speaker and run authority at persistence.

```sh
bun --no-env-file run build
node dist/daemon.js
```

Use a separate bounded service on the existing Finland ARM64 host; keep the SFU and API process independent. Do not deploy or activate from this package's local checks. Give service shutdown enough time for native exit and the final bounded API acknowledgement; an unconfirmed exit or receipt during API outage must remain unavailable until reconciled.

## Validation and qualification

```sh
bun --no-env-file run typecheck
bun --no-env-file run test
bun --no-env-file run lint
bun --no-env-file run build
```

Tests use public synthetic wire fixtures and actual compiled Node loopback HTTP/WebSocket/process fixtures. `GRID_TRANSCRIPTION_TEST_NODE=/absolute/path/to/node` selects the Node executable for process tests. Node 22.23.3 macOS ARM64 has exercised real parent/child SIGSTOP, parent SIGKILL, TERM/KILL escalation, held exit acknowledgements, delayed/lost claims, and stopped-receipt API recovery. The pinned Silero model has performed compiled Node 16/24 kHz inference. A local source-built LiveKit 1.13.7 lab with two synthetic publishers has exercised existing/new microphone subscription, real RTC PCM, per-speaker VAD, admission and final delivery through loopback provider wire; this is not proof of the deployed SFU version or paid provider behavior.

Still required before activation: intended Linux ARM64/glibc service and real SFU/token qualification; selected Soniox provider authentication, quota, final ordering/latency and multilingual/code-switching/overlap acceptance; real macOS button/Stop/late-join/history behavior; and load/billing measurement. Qualify the OpenAI alternative before configuring it for live capture. A two-provider benchmark is optional and is required only for a measured superiority claim. The bounded real-account attempt returned no result, so paid provider readiness remains unknown. The Grid iOS gate remains independently off pending physical-device acceptance.

The compiled `qualify` command consumes an intentionally supplied signed16LE mono `.pcm` file at the selected provider's exact rate (100 ms–12 seconds), sends it at realtime pace and commits once. It is a single-provider boundary smoke, not the meeting/VAD comparison. Inject `GRID_TRANSCRIPTION_OPENAI_API_KEY` or `GRID_TRANSCRIPTION_SONIOX_API_KEY` through the approved secret consumer. These qualification-only names differ from daemon keys so no ordinary credential inheritance is assumed.

```sh
node dist/qualify.js --help
node dist/qualify.js --model standard --pcm /absolute/path/short-24k-mono.pcm
node dist/qualify.js --model meeting --pcm /absolute/path/short-16k-mono.pcm --out /absolute/path/fresh-lab-result.json
```

Default stdout contains only model, duration, finalization latency and character count. Optional `--out` explicitly creates a local transcript artifact with mode 0600 and never overwrites a file. Use synthetic speech or supplied recordings from willing participants. Soniox's ordinary routing is US; EU requires an enabled regional project/key and a qualified endpoint change before deployment.
