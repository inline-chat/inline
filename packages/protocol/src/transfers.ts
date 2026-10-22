import { Method } from "./core.js"

/** Fixed transfer geometry shared by realtime V3 upload and download clients. */
export const INLINE_TRANSFER_PART_SIZE = 512 * 1024
export const INLINE_UPLOAD_MAX_PARTS = 1_000
export const INLINE_TRANSFER_MAX_LOCATOR_ID = 2_147_483_647n

/** Decimal byte limits, shared by native admission and legacy HTTP uploads. */
export const INLINE_MEDIA_UPLOAD_MAX_BYTES = {
  photo: 40_000_000,
  video: 500_000_000,
  document: 500_000_000,
  voice: 20_000_000,
} as const

/**
 * Transfer RPCs, idempotent by `client_upload_id`, `upload_id`, or the upload
 * manifest. These are the only application methods a transfer-only V3 socket
 * may execute besides `GET_ME`.
 */
export const TRANSFER_RPC_METHODS: ReadonlySet<Method> = new Set<Method>([
  Method.GET_FILE_PART,
  Method.SAVE_UPLOAD_PART,
  Method.GET_UPLOAD_STATE,
  Method.CREATE_UPLOAD,
  Method.FINISH_UPLOAD,
  Method.CANCEL_UPLOAD,
])

/** Methods without application side effects. Clients may retry them under a fresh request ID. */
export const READ_ONLY_RPC_METHODS: ReadonlySet<Method> = new Set<Method>([
  Method.GET_ME,
  Method.GET_PEER_PHOTO,
  Method.GET_CHAT_HISTORY,
  Method.GET_SPACE_MEMBERS,
  Method.GET_CHAT_PARTICIPANTS,
  Method.GET_CHATS,
  Method.GET_USER_SETTINGS,
  Method.GET_UPDATES_STATE,
  Method.GET_CHAT,
  Method.GET_UPDATES,
  Method.SEARCH_MESSAGES,
  Method.LIST_BOTS,
  Method.REVEAL_BOT_TOKEN,
  Method.GET_MESSAGES,
  Method.GET_BOT_COMMANDS,
  Method.GET_PEER_BOT_COMMANDS,
  Method.GET_BOT_PRESENCE,
  Method.GET_SESSIONS,
  Method.CHECK_USERNAME,
  Method.GET_SPACE_URL_PREVIEW_EXCLUSIONS,
  Method.GET_USER_GROUPS,
  Method.GET_SPACE_SETTINGS,
  Method.GET_SPACE,
  Method.GET_THREAD_REFERENCES,
  Method.GET_THREAD_SUBTHREADS,
  Method.GET_PEER_BOTS,
  Method.GET_MY_BOT_CAPABILITIES,
  Method.GET_GRID,
  Method.GET_GRID_HOME,
  Method.GET_EXTERNAL_PROFILE_PHOTO,
  Method.GET_CHAT_TRANSCRIPT,
  Method.SEARCH_EXTERNAL_RESOURCES,
  Method.LIST_CONNECTORS,
  Method.SEARCH_USERS,
  Method.RESOLVE_URL_PREVIEW,
  Method.GET_BOT_AGENT,
  Method.LIST_BOT_AGENTS,
  Method.GET_CONNECTOR_CONFIG,
  Method.GET_UPLOAD_STATE,
])

/**
 * Methods whose replay protection is the session's in-memory receive window
 * rather than a durable replay row. A resend after the window re-executes, so
 * every member must be idempotent or read-only.
 */
export const REPLAY_EXEMPT_METHODS: ReadonlySet<Method> = new Set<Method>([
  ...TRANSFER_RPC_METHODS,
  ...READ_ONLY_RPC_METHODS,
])
