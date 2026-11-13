import Auth
import Foundation
import InlineProtocol
import RealtimeV2

/// Focus reporting for processes without the app's realtime client, such as the
/// Intents extension the system wakes when a Focus starts or ends.
public enum FocusStatusDirectReport {
  /// Whether the signed-in user shares Focus with anyone. The app writes it so an
  /// extension never reports Focus for someone who shares it with nobody.
  public static func setSharing(_ sharing: Bool, userId: Int64) {
    UserDefaults.shared.set(sharing, forKey: sharingKey(userId: userId))
  }

  public static func isSharing(userId: Int64) -> Bool {
    UserDefaults.shared.bool(forKey: sharingKey(userId: userId))
  }

  /// Sends one report over a short-lived connection. Returns whether the server took it.
  @discardableResult
  public static func send(focused: Bool, timeout: Duration = .seconds(15)) async -> Bool {
    if !Auth.shared.getIsLoggedIn() {
      await Auth.shared.refreshFromStorage()
    }
    guard Auth.shared.getIsLoggedIn(),
          let userId = Auth.shared.getCurrentUserId(),
          isSharing(userId: userId)
    else { return false }

    let session = RealtimeDirectSession(
      transport: NegotiatingRealtimeTransport(
        auth: Auth.shared.handle,
        rsaPublicKeys: InlineProtocolTrustRoots.production,
        transportPreference: .stored(in: .shared)
      ),
      auth: Auth.shared.handle
    )
    await session.connectIfNeeded()
    let delivered: Bool
    do {
      let result = try await session.callRpcDirect(
        method: .setFocusStatus,
        input: .setFocusStatus(.with { $0.focused = focused }),
        timeout: timeout
      )
      if case .setFocusStatus = result { delivered = true } else { delivered = false }
    } catch {
      delivered = false
    }
    // Close before returning: the system may end the extension right after.
    await session.finish()
    return delivered
  }

  private static func sharingKey(userId: Int64) -> String {
    "focusStatus.sharing.\(userId)"
  }
}
