import AuthenticationServices

class WebAuthenticationSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
  private var webAuthSession: ASWebAuthenticationSession?

  func webAuthenticationSession(
    _ session: ASWebAuthenticationSession,

    didCompleteWithCallbackURL callbackURL: URL
  ) {}

  func webAuthenticationSession(
    _ session: ASWebAuthenticationSession,

    didFailWithError error: Error
  ) {}

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.windows.first ?? ASPresentationAnchor()
  }

  func authenticate(
    url: URL,

    callbackScheme: String,

    completion: @escaping (URL?, Error?) -> Void
  ) {
    webAuthSession = ASWebAuthenticationSession(
      url: url,
      callbackURLScheme: callbackScheme,
      completionHandler: completion
    )

    webAuthSession?.presentationContextProvider = self
    webAuthSession?.prefersEphemeralWebBrowserSession = true
    webAuthSession?.start()
  }
}
