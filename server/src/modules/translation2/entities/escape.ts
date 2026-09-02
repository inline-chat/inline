import { decodeString } from "micromark-util-decode-string"

const textReserved = /([\\*_`[\]()~=<>$|])/g
const characterReferences = /&(?:#\d{1,7}|#x[\da-f]{1,6}|[\da-z]{1,31});/gi
const markdownEscapablePunctuation = new Set(Array.from("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"))

export const isMarkdownEscapable = (character: string | undefined): boolean => {
  return character !== undefined && markdownEscapablePunctuation.has(character)
}

export const escapeMdText = (text: string, atLineStart = true): string => {
  return escapeMarkdownLineStarts(escapeLiteralReferences(text.replace(textReserved, "\\$1")), atLineStart)
}

/** Escape native text before it enters the document grammar. A literal line
 * prefix is not a list/heading, and indentation is not an implicit code block.
 * Standard references encode spaces/tabs without introducing custom markers.
 * The first chunk may start inside a line after a native entity boundary. */
export const escapeMarkdownLineStarts = (text: string, atLineStart = true): string => text
  .replace(/^( {0,3})(#{1,6}(?=[\t ]|$)|[+-](?=[\t -]|$)|\d{1,9}\.(?=[\t ]|$))/gm,
    (match, indent: string, marker: string, offset: number) => {
      if (!atLineStart && offset === 0) return match
      const escapedIndex = marker.endsWith(".") ? marker.length - 1 : 0
      return indent + marker.slice(0, escapedIndex) + "\\" + marker.slice(escapedIndex)
    })
  .replace(/^[\t ]+/gm, (indent, offset: number) => !atLineStart && offset === 0 ? indent
    : indent.replace(/ /g, "&#32;").replace(/\t/g, "&#9;"))

const escapeLiteralReferences = (text: string): string => text.replace(characterReferences,
  (reference) => decodeString(reference) === reference ? reference : `\\${reference}`)

export const escapeLinkUrl = (url: string): string => {
  // Preserve literal character-reference-looking text through Markdown's one
  // decode pass, without rewriting ordinary query separators or Inline URIs.
  const escaped = escapeLiteralReferences(url.replace(/[\\()<>]/g, "\\$&"))
  return /[\t ]/.test(url) ? `<${escaped}>` : escaped
}

export const unescapeLinkUrl = (url: string): string => decodeString(url)
