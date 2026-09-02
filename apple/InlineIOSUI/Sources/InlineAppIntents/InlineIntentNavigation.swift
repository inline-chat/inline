import InlineKit
import Auth

/// The app supplies its existing scene router at launch; the intents own no navigation state.
public struct InlineIntentNavigation: Sendable {
  let openChat: @MainActor @Sendable (Peer, Int64) -> Bool

  public init(openChat: @escaping @MainActor @Sendable (Peer, Int64) -> Bool) {
    self.openChat = openChat
  }
}

/// The app adapter waits for its existing composer and preserves any draft already being edited.
public struct InlineIntentDraftNavigation: Sendable {
  let compose: @MainActor @Sendable (Peer, AuthAccountMutationToken, String) async throws -> Void
  public init(compose: @escaping @MainActor @Sendable (Peer, AuthAccountMutationToken, String) async throws -> Void) {
    self.compose = compose
  }
}
