# Inline web

An experimental real Inline client built with React, Vite, and TanStack Router.
It uses the existing Inline authentication, binary protocol, custom local database,
sync engine, and durable outbox. The application contains no demo accounts or chats.

## Run locally

From the repository root:

```sh
bun --no-env-file install --ignore-scripts
bun --no-env-file run --cwd web dev
```

Open `http://127.0.0.1:8010/`. Email verification signs into the real Inline service.
The dev server proxies authentication requests to the API; realtime connects directly.
Configuration is explicit and does not load `.env` files. To select another API,
prefix the command with `INLINE_WEB_API_ORIGIN=https://your-api.example`.

## Scope and ownership

- Email sign-in, spaces, pinned threads, people, cached conversation-title search, and private thread creation.
- Text history, replies, persisted draft text, durable sending/retry, and focused visible-message reads.
  Reply selection belongs to the current pane; reply quotes require the referenced message in its resident window.
- Basic existing photo/document/voice/video display using browser-supported formats, appearance, and sidebar density.
- One account owns one IndexedDB replica and one realtime connection under a browser Web Lock.
  Other tabs wait and take over when the writer closes.
- One pane owns one conversation. Routes prepare cached messages and drafts before rows mount;
  fresh history runs independently. Earlier history loads manually; the visible conversation stays bounded to 200 messages.
- Message/outbox acceptance and matching draft consumption share an atomic local transaction.
  Shutdown retires views, drains queued drafts and realtime, then closes storage and releases ownership.

No new server endpoints, protocol fields, or database migrations are required.
The shared client additionally handles access-removal cache invalidation, delayed snapshot
and disk-read admission, monotonic read frontiers, and interrupted sync discovery cleanup.
Sign-in loads separately from the account runtime, and saved appearance applies before the first render.

## Build gate

```sh
bun --no-env-file run --cwd web typecheck
bun --no-env-file run --cwd web test
bun --no-env-file run --cwd web build
bun --no-env-file run --cwd web build:experimental
```

The ordinary production build displays a disabled-client page and excludes the application
module. Only explicit experimental mode enables the client. Serve experimental builds on
an API-approved origin with HTTPS and browser storage/Web Locks support; deep links need
an HTML fallback. Local `vite preview` does not provide the development auth proxy.

This client is not yet qualified for production. Uploads, calls, global message search,
rich message/action parity, independent interactive tabs, and offline shell installation
remain outside this slice. Cached API-offline conversations differ from loading the app
with the browser network completely disabled. Browser matrix, difficult-network UI checks,
and signed-in production acceptance are required before lifting the gate.

## Isolated protocol qualification

The fixture is a separate development process using the canonical binary codecs. It is
never bundled into the app and never connects to production:

```sh
bun --no-env-file web/tests/protocol-server.ts
INLINE_WEB_API_ORIGIN=http://127.0.0.1:8012 bun --no-env-file run --cwd web dev -- --port 8011
```

At `http://127.0.0.1:8011/`, use fixture email `web-test@example.test` and code `123456`.
`GET /test/state` provides aggregate method/send counts. `POST /test/network` with
`{"online":false}` or `{"online":true}` controls fixture availability. `POST /test/message`
with `{"message":"Incoming fixture message"}` emits an actual protocol update.
These controls affect only the fixture and are not product APIs.

With the fixture running, run the manual qualification from a second terminal at the
repository root:

```sh
(cd web && bun --no-env-file tests/protocol-qualification.ts)
```

This script uses the production `RealtimeClient`, `Db`, and `Conversation` with real
loopback WebSockets and an isolated `fake-indexeddb` store. It checks POST authentication,
exact IDs above JavaScript's safe integer range, latest/older history, draft consumption,
online sending, an offline accepted send surviving closed and recreated owners with the
same retry identity, certified error-free latest history after both sends, one canonical row,
an empty outbox with no orphan Sending rows, live updates, and bounded shutdown. It restores
fixture availability and drains its owners in `finally`, then prints aggregate JSON.
Each run adds synthetic messages; restart the fixture for a fresh 160-message history.

The access qualification starts and closes its own loopback server on an ephemeral port;
it can run independently of the browser fixture:

```sh
(cd web && bun --no-env-file tests/protocol-access-qualification.ts)
```

It checks a public Space whose legacy child inherits access through its parent. A matched
live eviction preserves cached access while authoritative user replay is held; committing
the durable removal clears the Space, parent, child, dialogs, and indexed history while
preserving the draft and authentication. An immutable old history response cannot restore
removed data. Reload excludes the removed cache, then a new membership restores current
metadata and requires fresh history certification. An obsolete membership eviction triggers
an `EMPTY` user replay with no sidecars and preserves the newer grant. Fixture replay sidecars
are limited to references in nonempty pages; it does not model the server's complete ACL or
claim a production incident. These test controls use existing protocol shapes and remain
separate from product APIs.

This qualifies the transport and persistence adapter logic in Bun. It does not qualify
browser rendering, scroll or keyboard behavior, browser Web Locks and tab handoff,
native browser IndexedDB durability, process crashes, API-offline reload UI, or production
authentication and connectivity. Browser and signed-in production acceptance remain required.

Core tests also exercise IndexedDB adapter transactions through `fake-indexeddb` and
actual protocol frames where transport behavior matters. They include delayed responses,
committed access loss, read-state races, account handoff, draft draining, and durable
send/retry identity.
