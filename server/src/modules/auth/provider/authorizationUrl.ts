export function applyAppleAuthorizationParameters(url: URL, nonce: string): void {
  url.searchParams.set("nonce", nonce)
  url.searchParams.set("response_mode", "form_post")
}
