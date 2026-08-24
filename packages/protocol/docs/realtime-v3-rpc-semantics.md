# Realtime V3 RPC semantics

Status: normative replay, reconciliation, and ordering map for the `Method` enum in `proto/core.proto`. The protobuf and server handler remain the schema/behavior sources of truth; this document makes their reliability obligations independently testable.

## Rules

- “Repeat-safe” means the same logical request may be sent again without creating a second logical mutation. It does not mean free of rate limits, provider cost, secret exposure, or fresh timestamps.
- `accepted` is diagnostic. Only an authenticated result/update or authoritative query confirms outcome.
- After dispatch, an unclassified mutation becomes `commitUnknown` on timeout, cancellation, disconnect, or missing result. It is never transport-replayed.
- A server deadline before application execution is an outer MTProto `rpc_result` containing TL `rpc_error(503, ...)`; it is a cached `rejectedBeforeExecution` result. After execution begins, the same deadline uses TL `rpc_error(504, ...)`, which clients map to request-local `commitUnknown` without closing the healthy session. A protobuf `RpcError` nested inside `inline.result` remains an ordinary application error even when its numeric code is 503/504; HTTP-like status values never define commit uncertainty.
- Stable-identity methods are retryable only when the stated identity is present and reused. Otherwise they are commit-unknown.
- Set/delete-shaped methods are not assumed idempotent: many emit revisions, system messages, notifications, or an error when repeated.
- `UNSPECIFIED` is always rejected before execution.

## Repeat-safe queries

These may use reconnect replay while preserving their exact input:

```text
GET_ME GET_PEER_PHOTO GET_CHAT_HISTORY GET_SPACE_MEMBERS
GET_CHAT_PARTICIPANTS GET_CHATS GET_USER_SETTINGS GET_UPDATES_STATE
GET_CHAT GET_SPACE GET_UPDATES SEARCH_MESSAGES LIST_BOTS REVEAL_BOT_TOKEN
GET_MESSAGES GET_BOT_COMMANDS GET_PEER_BOT_COMMANDS GET_BOT_PRESENCE
GET_SESSIONS CHECK_USERNAME GET_SPACE_URL_PREVIEW_EXCLUSIONS GET_USER_GROUPS
GET_SPACE_SETTINGS GET_THREAD_REFERENCES GET_THREAD_SUBTHREADS GET_PEER_BOTS
GET_MY_BOT_CAPABILITIES GET_GRID GET_GRID_HOME GET_EXTERNAL_PROFILE_PHOTO
GET_CHAT_TRANSCRIPT SEARCH_EXTERNAL_RESOURCES LIST_CONNECTORS SEARCH_USERS
RESOLVE_URL_PREVIEW GET_BOT_AGENT LIST_BOT_AGENTS GET_CONNECTOR_CONFIG
GET_UPLOAD_STATE
```

`GET_GRID`/`GET_GRID_HOME` refresh presence leases. External search/preview calls may consume provider/rate budget. `REVEAL_BOT_TOKEN` is credential-sensitive. These effects do not create duplicate product entities, but callers still avoid speculative fan-out.

## Stable identity or authoritative reconciliation

These are not a blanket automatic-replay list. The caller must preserve the condition and reconcile the authoritative result:

| Method | Required identity / condition |
| --- | --- |
| `SEND_MESSAGE` | Non-zero stable `random_id`; absent/zero is never replay-safe. |
| `TRANSLATE_MESSAGES` | `(message, chat, language)` and revision-aware replacement; reconcile rather than blind replay. |
| `ADD_CHAT_PARTICIPANT` | Existing membership path returns the participant; verify target membership. |
| `CREATE_SUBTHREAD` | Only anchored `(parent chat, parent message)` subthreads; unanchored creation has no identity. |
| `REVOKE_SESSION` | Server distinguishes revoked/already-revoked. |
| `ADD_SPACE_URL_PREVIEW_EXCLUSION` | Unique space/host/path; reconcile because first application has attachment side effects. |
| `SET_MY_BOT_CAPABILITIES` | Atomic full-set replacement plus SDK-owned reconnect reconciliation. |
| `JOIN_GRID_ROOM` | Existing membership is reused, but credentials/leases may rotate; query Grid state. |
| `JOIN_PUBLIC_SPACE` | Existing membership returns already-member. |
| `CREATE_UPLOAD` | `(account session, client_upload_id)`. |
| `SAVE_UPLOAD_PART` | `(upload_id, part_index, matching hash/bytes)`. |
| `FINISH_UPLOAD` | Stable `upload_id`; publication reserves one deterministic file identity and replays return the cached canonical result. |

## State-shaped; no automatic replay

These target existing state, but current semantics do not prove that a repeated call is response- or side-effect-equivalent:

```text
DELETE_MESSAGES DELETE_REACTION EDIT_MESSAGE DELETE_CHAT DELETE_MEMBER
REMOVE_CHAT_PARTICIPANT UPDATE_USER_SETTINGS MARK_AS_UNREAD READ_MESSAGES
UPDATE_MEMBER_ACCESS UPDATE_CHAT_VISIBILITY PIN_MESSAGE UPDATE_CHAT_INFO
UPDATE_BOT_PROFILE UPDATE_DIALOG_NOTIFICATION_SETTINGS REGISTER_DEVICE
SET_BOT_COMMANDS SHOW_IN_CHAT_LIST UPDATE_DIALOG_OPEN UPDATE_DIALOG_ORDER
DELETE_BOT DELETE_MESSAGE_ATTACHMENT SET_BOT_AVATAR CLEAR_BOT_AVATAR
SET_BOT_PRESENCE_STATE UPDATE_DIALOG_FOLLOW_MODE CHANGE_USERNAME UPDATE_PROFILE
REMOVE_SPACE_URL_PREVIEW_EXCLUSION UPDATE_USER_GROUP DELETE_USER_GROUP
TOGGLE_SPACE_GRID LEAVE_GRID_ROOM SET_GRID_ROOM_TITLE SET_GRID_ROOM_LOCKED
DELETE_GRID_ROOM SET_PROFILE_PHOTO COLLAPSE_HISTORY DISCONNECT_CONNECTOR
DELETE_SPACE LEAVE_SPACE SET_CONNECTOR_CONFIG UNREGISTER_DEVICE CANCEL_UPLOAD
UPDATE_SESSION UPDATE_DIALOG_ARCHIVED
```

On `commitUnknown`, query/reconcile the target before offering a deliberate retry. Examples: repeated delete/remove may error after success; pinning can create a system message; presence/microphone setters advance revisions; `UPDATE_DIALOG_OPEN` can schedule empty-thread deletion; processing upload cancellation is intentionally refused.

## Non-idempotent or execution-sensitive

These allocate, rotate, invoke an action, depend on time, or cross an irreversible lifecycle boundary. They require a new stable operation identity before any general automatic retry can be enabled:

```text
ADD_REACTION CREATE_CHAT INVITE_TO_SPACE SEND_COMPOSE_ACTION CREATE_BOT
FORWARD_MESSAGES MOVE_THREAD ROTATE_BOT_TOKEN RESERVE_CHAT_IDS
INVOKE_MESSAGE_ACTION ANSWER_MESSAGE_ACTION CLEAR_CHAT_HISTORY CREATE_USER_GROUP
REQUEST_BOT_CHAT_SETTINGS INVOKE_BOT_CHAT_SETTINGS_ITEM ANSWER_BOT_CHAT_SETTINGS
CREATE_GRID_ROOM PREPARE_GRID_CONNECTION SET_GRID_AVATAR_MICROPHONE_ENABLED
CREATE_CLI_SESSION PREPARE_CONNECTOR_OAUTH INVITE_TO_INLINE CREATE_BOT_AGENT
CREATE_SPACE CREATE_EXTERNAL_TASK LOG_OUT
```

`SEND_COMPOSE_ACTION` is ephemeral: cancellation means stop waiting, not replay. `LOG_OUT` uses marker-first local destruction even if its result is lost. A lost `FINISH_UPLOAD` result is still reported as commit-unknown at the request boundary, then reconciled or deliberately retried with the same upload ID.

## Ordering

Connection-local execution lanes serialize selected non-commutative operations for `chat:<id>`, `user:<id>`, `space:<id>`, or `account:settings`. Unrelated keys remain concurrent. `invokeAfter` may express a proven same-session dependency. Neither mechanism replaces cross-connection database transactions/row locks, and neither makes a method replay-safe.

Acceptance tests for every promoted replay-safe mutation must cover: first execution, identical replay, concurrent duplicate, commit-then-drop-result, authoritative reconciliation, and a mismatched identity/input rejection. No method moves categories based only on its name.
