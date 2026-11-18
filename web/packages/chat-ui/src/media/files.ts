/**
 * Text and small models for documents, voice messages and video badges.
 *
 * Mac parity:
 * - File sizes: `ByteCountFormatter` with `.file` style (`InlineKit/Files/FileHelpers.swift`):
 *   decimal units (1 KB = 1000 bytes), bytes, KB with no decimals, MB with
 *   one, GB with two. Numbers go through `Intl.NumberFormat`; unit labels are
 *   the Mac's.
 * - Durations: `m:ss`, `h:mm:ss` from one hour (`NewVideoView.swift`,
 *   `VoiceMessageBubble.swift`).
 * - Waveform: 48 bars, bucket maximum, relative scale, `pow(0.72)`, at least
 *   0.12; an empty waveform draws flat bars at 0.12 (`AudioWaveformView.swift`).
 * - Document icons: by MIME type, then extension (`DocumentIconResolver.swift`),
 *   reduced to the categories a web icon set needs.
 */

import type { DocumentInfo, VoiceInfo } from "@inline/core-protocol"

export type FormatLocale = string | readonly string[] | undefined

const numberFormat = (locale: FormatLocale, fractionDigits: number): Intl.NumberFormat => {
  const options: Intl.NumberFormatOptions = { maximumFractionDigits: fractionDigits, minimumFractionDigits: 0 }
  try {
    return new Intl.NumberFormat(locale as string | string[] | undefined, options)
  } catch {
    return new Intl.NumberFormat(undefined, options)
  }
}

const byteUnits = [
  { label: "KB", factor: 1e3, digits: 0 },
  { label: "MB", factor: 1e6, digits: 1 },
  { label: "GB", factor: 1e9, digits: 2 },
] as const

/** "512 bytes", "52 KB", "9.5 MB", "1.25 GB". Negative or non-finite sizes are 0. */
export const formatFileSize = (bytes: number, locale?: FormatLocale): string => {
  const value = Number.isFinite(bytes) && bytes > 0 ? Math.round(bytes) : 0
  if (value < 1000) return `${numberFormat(locale, 0).format(value)} ${value === 1 ? "byte" : "bytes"}`
  for (let index = 0; index < byteUnits.length; index += 1) {
    const unit = byteUnits[index]
    if (!unit) break
    const scaled = value / unit.factor
    const rounded = Math.round(scaled * 10 ** unit.digits) / 10 ** unit.digits
    if (rounded < 1000 || index === byteUnits.length - 1) {
      return `${numberFormat(locale, unit.digits).format(rounded)} ${unit.label}`
    }
  }
  return `${value} bytes`
}

/** "0:07", "1:15", "1:02:03". Rounds to whole seconds; negative or non-finite is 0. */
export const formatDuration = (seconds: number): string => {
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds) : 0
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const secs = total % 60
  const two = (value: number) => String(value).padStart(2, "0")
  return hours > 0 ? `${hours}:${two(minutes)}:${two(secs)}` : `${minutes}:${two(secs)}`
}

export type FileIcon =
  | "pdf"
  | "image"
  | "video"
  | "audio"
  | "archive"
  | "code"
  | "text"
  | "spreadsheet"
  | "presentation"
  | "document"

const iconByExtension: Readonly<Record<string, FileIcon>> = {
  pdf: "pdf",
  png: "image",
  jpg: "image",
  jpeg: "image",
  gif: "image",
  webp: "image",
  heic: "image",
  svg: "image",
  mp4: "video",
  mov: "video",
  webm: "video",
  mkv: "video",
  mp3: "audio",
  m4a: "audio",
  wav: "audio",
  ogg: "audio",
  flac: "audio",
  zip: "archive",
  gz: "archive",
  tgz: "archive",
  tar: "archive",
  rar: "archive",
  "7z": "archive",
  dmg: "archive",
  js: "code",
  ts: "code",
  tsx: "code",
  jsx: "code",
  swift: "code",
  rs: "code",
  py: "code",
  go: "code",
  java: "code",
  kt: "code",
  c: "code",
  h: "code",
  cpp: "code",
  json: "code",
  yaml: "code",
  yml: "code",
  html: "code",
  css: "code",
  sh: "code",
  txt: "text",
  md: "text",
  rtf: "text",
  log: "text",
  csv: "spreadsheet",
  xls: "spreadsheet",
  xlsx: "spreadsheet",
  numbers: "spreadsheet",
  ppt: "presentation",
  pptx: "presentation",
  key: "presentation",
  doc: "document",
  docx: "document",
  pages: "document",
}

/** The extension of a file name, lowercased, without the dot; undefined when it has none. */
export const fileExtension = (fileName: string): string | undefined => {
  const dot = fileName.lastIndexOf(".")
  if (dot <= 0 || dot === fileName.length - 1) return undefined
  return fileName.slice(dot + 1).toLowerCase()
}

export const fileIcon = (mimeType: string, fileName: string): FileIcon => {
  const mime = mimeType.toLowerCase().split(";")[0]?.trim() ?? ""
  if (mime === "application/pdf") return "pdf"
  if (mime.startsWith("image/")) return "image"
  if (mime.startsWith("video/")) return "video"
  if (mime.startsWith("audio/")) return "audio"
  if (/zip|compressed|x-tar|gzip|x-7z|x-rar/.test(mime)) return "archive"
  if (/spreadsheet|ms-excel|csv/.test(mime)) return "spreadsheet"
  if (/presentation|powerpoint/.test(mime)) return "presentation"
  const extension = fileExtension(fileName)
  const byExtension = extension ? iconByExtension[extension] : undefined
  if (byExtension) return byExtension
  if (mime.startsWith("text/")) return "text"
  return "document"
}

export type DocumentRowModel = {
  readonly kind: "document"
  /** The file name as text; "File" when empty. Render as a text node, middle-truncated. */
  readonly name: string
  readonly extension: string | undefined
  readonly icon: FileIcon
  /** "52 KB". */
  readonly sizeText: string
  /** Show the thumbnail (70 px, radius 8) instead of the icon (36 px circle). */
  readonly hasThumbnail: boolean
  /** Row height: 36, or 70 with a thumbnail. */
  readonly height: number
  /** The row is at least this wide (Mac `DocumentFileLayout`). */
  readonly minWidth: number
}

export const documentRowModel = (document: DocumentInfo, locale?: FormatLocale): DocumentRowModel => {
  const name = document.fileName.trim().length > 0 ? document.fileName : "File"
  const hasThumbnail = document.thumbnail !== undefined && document.thumbnail.sizes.length > 0
  return {
    kind: "document",
    name,
    extension: fileExtension(name),
    icon: fileIcon(document.mimeType, name),
    sizeText: formatFileSize(document.size, locale),
    hasThumbnail,
    height: hasThumbnail ? 70 : 36,
    minWidth: 200,
  }
}

export const waveformBarCount = 48
export const waveformMinLevel = 0.12

/**
 * Bar heights in [0.12, 1] from waveform samples (0 to 255): the maximum of
 * each bucket, scaled relative to the waveform's range, then `pow(0.72)`.
 */
export const waveformBars = (samples: Uint8Array | undefined, count = waveformBarCount): number[] => {
  const bars = Math.max(1, Math.floor(count))
  if (!samples || samples.length === 0) return Array.from({ length: bars }, () => waveformMinLevel)
  const buckets: number[] = []
  for (let bar = 0; bar < bars; bar += 1) {
    const from = Math.floor((bar * samples.length) / bars)
    const to = Math.max(from + 1, Math.floor(((bar + 1) * samples.length) / bars))
    let max = 0
    for (let index = from; index < to && index < samples.length; index += 1) max = Math.max(max, samples[index] ?? 0)
    buckets.push(max / 255)
  }
  const min = Math.min(...buckets)
  const spread = Math.max(...buckets) - min
  return buckets.map((value) => {
    const relative = spread > 0 ? Math.max(value, (value - min) / spread) : value
    return Math.max(waveformMinLevel, Math.min(1, relative ** 0.72))
  })
}

export type VoiceRowModel = {
  readonly kind: "voice"
  /** "0:12": the total; the view shows the playhead's time while playing. */
  readonly durationText: string
  readonly duration: number
  readonly bars: readonly number[]
  readonly sizeText: string
  /** Row size (Mac `Theme` voice bubble). */
  readonly width: number
  readonly height: number
}

export const voiceRowModel = (voice: VoiceInfo, locale?: FormatLocale): VoiceRowModel => ({
  kind: "voice",
  durationText: formatDuration(voice.duration),
  duration: voice.duration,
  bars: waveformBars(voice.waveform),
  sizeText: formatFileSize(voice.size, locale),
  width: 216,
  height: 44,
})
