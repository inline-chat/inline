import { EMAIL_PROVIDER, isProd } from "@in/server/env"

export const IS_PROD = isProd
export { EMAIL_PROVIDER }

export const MAX_FILE_SIZE = 500 * 1024 * 1024 // 500 MB

// export const CDN_URL_FOR_R2 = isProd ? "https://cdn.inline.chat" : "https://dev-cdn.inline.chat"
export const FILES_PATH_PREFIX = "files" // so stored in "files/.../....png"
