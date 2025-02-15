export const IS_PROD = process.env.NODE_ENV === "production"

export const EMAIL_PROVIDER: "SES" | "RESEND" = process.env["EMAIL_PROVIDER"] === "SES" ? "SES" : "RESEND"

export const MAX_FILE_SIZE = 500 * 1024 * 1024 // 500 MB

// export const CDN_URL_FOR_R2 = isProd ? "https://cdn.inline.chat" : "https://dev-cdn.inline.chat"
export const FILES_PATH_PREFIX = "files" // so stored in "files/.../....png"
