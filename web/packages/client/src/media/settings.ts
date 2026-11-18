import {
  AUTO_DOWNLOAD_DEFAULT_FILE_MB,
  AUTO_DOWNLOAD_DEFAULT_MEDIA_MB,
  AUTO_DOWNLOAD_DEFAULT_VOICE_MB,
  AUTO_DOWNLOAD_MAX_MB,
  DEFAULT_CACHE_BUDGET_BYTES,
} from "./constants"

/** `AutoDownloadKind` in `AutoDownloadSettings.swift`: photos and videos, documents, voice. */
export type AutoDownloadKind = "media" | "file" | "voice"

export type AutoDownloadLimits = {
  readonly mediaMaxMB: number
  readonly fileMaxMB: number
  readonly voiceMaxMB: number
}

export type MediaSettings = {
  readonly autoDownload: AutoDownloadLimits
  /** Bytes the download cache may hold. Pinned entries can exceed it. */
  readonly cacheBudgetBytes: number
  /** Keep Media: downloads older than this many days are removed by the sweep. 0 keeps them. `StorageKeepMedia`. */
  readonly keepMediaDays: number
}

export const defaultMediaSettings: MediaSettings = {
  autoDownload: {
    mediaMaxMB: AUTO_DOWNLOAD_DEFAULT_MEDIA_MB,
    fileMaxMB: AUTO_DOWNLOAD_DEFAULT_FILE_MB,
    voiceMaxMB: AUTO_DOWNLOAD_DEFAULT_VOICE_MB,
  },
  cacheBudgetBytes: DEFAULT_CACHE_BUDGET_BYTES,
  keepMediaDays: 0,
}

/** `AutoDownloadSettingsManager.clamped`. */
export const clampMegabytes = (value: number): number =>
  Math.min(Math.max(Number.isFinite(value) ? Math.trunc(value) : 0, 0), AUTO_DOWNLOAD_MAX_MB)

/**
 * `AutoDownloadSettingsManager.shouldDownload`: an unknown or empty size is
 * never fetched automatically, a limit of 0 turns the kind off, and a
 * megabyte is 1024 * 1024 bytes.
 */
export const shouldAutoDownload = (limits: AutoDownloadLimits, kind: AutoDownloadKind, sizeBytes: number | undefined): boolean => {
  if (sizeBytes === undefined || !(sizeBytes > 0)) return false
  const maxMB = clampMegabytes(kind === "media" ? limits.mediaMaxMB : kind === "file" ? limits.fileMaxMB : limits.voiceMaxMB)
  if (maxMB <= 0) return false
  return sizeBytes <= maxMB * 1024 * 1024
}
