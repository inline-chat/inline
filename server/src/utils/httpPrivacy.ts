/** Keep credentials out of diagnostics without changing the URL used for routing. */
export const redactCredentialPath = (path: string): string => path
  .replace(/(\/v1\/)[^/\s?#]+(?=\/)/gi, "$1<redacted>")
  .replace(/\/bot(?!-api-reference(?:\/|$))[^/\s?#]+(?=\/|$)/gi, "/bot<redacted>")

/** These APIs can return credentials or private content, including on GET/error paths. */
export const requiresPrivateResponse = (path: string): boolean =>
  /^\/v1(?:\/|$)/i.test(path) ||
  (/^\/bot(?:[^/]*)(?:\/|$)/i.test(path) && !/^\/bot-api-reference(?:\/|$)/i.test(path))
