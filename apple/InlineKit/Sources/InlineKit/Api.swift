import Auth
import InlineProtocol
import RealtimeV2

/// Wrapper
public enum Api {
  public static let realtime = RealtimeV2(
    transport: WebSocketTransport2(),
    auth: Auth.shared,
    applyUpdates: InlineApplyUpdates()
  )
}
