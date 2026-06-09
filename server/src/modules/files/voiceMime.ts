export type VoiceMimeType = "audio/ogg" | "audio/mp4" | "audio/x-m4a"

export type VoiceMimeResolution =
  | {
      ok: true
      mimeType: VoiceMimeType
      extension: string | undefined
    }
  | {
      ok: false
      reason: "missing-type-and-extension" | "unsupported-mime" | "unsupported-extension" | "mismatch"
      mimeType: string | undefined
      extension: string | undefined
    }

export const validVoiceMimeTypes: VoiceMimeType[] = ["audio/ogg", "audio/mp4", "audio/x-m4a"]

export const validVoiceExtensionsForMimeType: Record<VoiceMimeType, string[]> = {
  "audio/ogg": ["ogg", "oga"],
  "audio/mp4": ["m4a", "mp4"],
  "audio/x-m4a": ["m4a", "mp4"],
}

export const voiceMimeTypeForExtension: Record<string, VoiceMimeType> = {
  ogg: "audio/ogg",
  oga: "audio/ogg",
  m4a: "audio/mp4",
  mp4: "audio/mp4",
}

export const validVoiceExtensions = Object.keys(voiceMimeTypeForExtension)

export function resolveVoiceMimeType({
  mimeType,
  path,
  extension,
  allowExtensionFallbackForInvalidMime = false,
}: {
  mimeType: string | null | undefined
  path?: string | null | undefined
  extension?: string | null | undefined
  allowExtensionFallbackForInvalidMime?: boolean
}): VoiceMimeResolution {
  const normalizedMimeType = normalizeVoiceMimeType(mimeType)
  const normalizedExtension = normalizeVoiceExtension(extension ?? pathExtension(path))
  const mimeTypeFromExtension = normalizedExtension ? voiceMimeTypeForExtension[normalizedExtension] : undefined
  const unsupportedMimeType = mimeType?.trim() ? mimeType.trim().toLowerCase() : undefined

  if (
    normalizedMimeType &&
    normalizedExtension &&
    !validVoiceExtensionsForMimeType[normalizedMimeType].includes(normalizedExtension)
  ) {
    return {
      ok: false,
      reason: "mismatch",
      mimeType: normalizedMimeType,
      extension: normalizedExtension,
    }
  }

  if (normalizedMimeType) {
    return {
      ok: true,
      mimeType: normalizedMimeType,
      extension: normalizedExtension,
    }
  }

  if (unsupportedMimeType) {
    if (allowExtensionFallbackForInvalidMime && mimeTypeFromExtension) {
      return {
        ok: true,
        mimeType: mimeTypeFromExtension,
        extension: normalizedExtension,
      }
    }

    return {
      ok: false,
      reason: "unsupported-mime",
      mimeType: unsupportedMimeType,
      extension: normalizedExtension,
    }
  }

  if (mimeTypeFromExtension) {
    return {
      ok: true,
      mimeType: mimeTypeFromExtension,
      extension: normalizedExtension,
    }
  }

  if (normalizedExtension) {
    return {
      ok: false,
      reason: "unsupported-extension",
      mimeType: undefined,
      extension: normalizedExtension,
    }
  }

  return {
    ok: false,
    reason: "missing-type-and-extension",
    mimeType: undefined,
    extension: undefined,
  }
}

export function normalizeVoiceMimeType(mimeType: string | null | undefined): VoiceMimeType | undefined {
  const normalized = mimeType?.trim().toLowerCase()
  if (!normalized) return undefined
  return validVoiceMimeTypes.includes(normalized as VoiceMimeType) ? (normalized as VoiceMimeType) : undefined
}

export function normalizeVoiceExtension(extension: string | null | undefined): string | undefined {
  const normalized = extension?.trim().toLowerCase().replace(/^\.+/, "")
  if (!normalized) return undefined
  return normalized
}

export function pathExtension(path: string | null | undefined): string | undefined {
  const cleanPath = path?.split(/[?#]/, 1)[0]
  const name = cleanPath?.split("/").pop()
  const lastDot = name?.lastIndexOf(".") ?? -1
  if (!name || lastDot <= 0 || lastDot === name.length - 1) return undefined
  return normalizeVoiceExtension(name.slice(lastDot + 1))
}
