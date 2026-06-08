const longestBacktickRun = (text: string): number => {
  let longest = 0
  let current = 0

  for (const char of text) {
    if (char === "`") {
      current += 1
      longest = Math.max(longest, current)
    } else {
      current = 0
    }
  }

  return longest
}

export const codeDelimiter = (text: string): string => {
  return "`".repeat(Math.max(1, longestBacktickRun(text) + 1))
}

export const preFence = (text: string): string => {
  return "`".repeat(Math.max(3, longestBacktickRun(text) + 1))
}

export const cleanPreLanguage = (language: string | undefined): string => {
  const trimmed = language?.trim() ?? ""
  if (!/^[A-Za-z0-9_+.#-]{0,64}$/.test(trimmed)) {
    return ""
  }
  return trimmed
}
