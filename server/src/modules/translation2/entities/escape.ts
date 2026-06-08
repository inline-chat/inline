const textReserved = /([\\*_`[\]()])/g

export const escapeMdText = (text: string): string => {
  return text.replace(textReserved, "\\$1")
}

export const escapeLinkUrl = (url: string): string => {
  return url.replace(/\\/g, "\\\\").replace(/\)/g, "\\)")
}

export const unescapeLinkUrl = (url: string): string => {
  let result = ""
  for (let i = 0; i < url.length; i++) {
    if (url[i] === "\\" && i + 1 < url.length) {
      result += url[i + 1]
      i += 1
      continue
    }
    result += url[i]
  }
  return result
}
