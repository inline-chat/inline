import Combine
import Foundation

/// Experimental: used to gate chat list updates when the list is off-screen.
/// This can change UX (e.g., deferred animations/updates while not visible).
@MainActor
final class ChatListVisibilityGate: ObservableObject {
  static let shared = ChatListVisibilityGate()

  @Published var isVisible: Bool = false

  private init() {}
}
