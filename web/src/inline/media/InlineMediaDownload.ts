type InlineWritableFile = WritableStream<Uint8Array> & {
  abort?: (reason?: unknown) => Promise<void>
}

type InlineSaveFileHandle = {
  createWritable(): Promise<InlineWritableFile>
}

type InlineSaveFilePicker = (options: {
  suggestedName: string
}) => Promise<InlineSaveFileHandle>

export type InlineMediaDownloadProgress = {
  receivedBytes: number
  totalBytes?: number
}

export type InlineMediaDownloadResult =
  | { method: "native" }
  | { method: "stream"; bytesWritten: number }

export const inlineDownloadFileName = (value: string) => {
  const safeCharacters = Array.from(value, (character) => {
    const codePoint = character.codePointAt(0) ?? 0
    return codePoint <= 31 ||
      codePoint === 127 ||
      character === "/" ||
      character === "\\" ||
      character === ":"
      ? "-"
      : character
  }).join("")
  const normalized = safeCharacters
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 180)
  return normalized || "Inline download"
}

const anchorDownload = (url: string, fileName: string) => {
  const anchor = document.createElement("a")
  anchor.href = url
  anchor.download = fileName
  anchor.rel = "noopener noreferrer"
  anchor.click()
}

/**
 * Streams remote media directly to a user-selected file in Chromium when the
 * File System Access API is available. Blob URLs and fallback browsers use the
 * native download path without copying bytes through another app-owned cache.
 */
export async function downloadInlineMedia(
  url: string,
  requestedFileName: string,
  options: {
    signal?: AbortSignal
    onProgress?: (progress: InlineMediaDownloadProgress) => void
  } = {},
): Promise<InlineMediaDownloadResult> {
  const fileName = inlineDownloadFileName(requestedFileName)
  const savePicker = (
    window as typeof window & {
      showSaveFilePicker?: InlineSaveFilePicker
    }
  ).showSaveFilePicker
  if (!savePicker || url.startsWith("blob:")) {
    anchorDownload(url, fileName)
    return { method: "native" }
  }

  const handle = await savePicker({ suggestedName: fileName })
  const response = await fetch(url, {
    credentials: "omit",
    signal: options.signal,
  })
  if (!response.ok || !response.body) {
    throw new Error(`Inline media download failed (${response.status})`)
  }
  const writable = await handle.createWritable()
  const headerLength = Number(response.headers.get("content-length"))
  const totalBytes = Number.isFinite(headerLength) && headerLength >= 0
    ? headerLength
    : undefined
  let bytesWritten = 0
  const progress = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      bytesWritten += chunk.byteLength
      options.onProgress?.({ receivedBytes: bytesWritten, totalBytes })
      controller.enqueue(chunk)
    },
  })
  try {
    await response.body
      .pipeThrough(progress)
      .pipeTo(writable, { signal: options.signal })
  } catch (cause) {
    await writable.abort?.(cause).catch(() => undefined)
    throw cause
  }
  return { method: "stream", bytesWritten }
}
