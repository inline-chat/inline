import Foundation

/// Keeps Foundation's WebSocket receive budget aligned with Inline's authenticated packet bound.
public enum InlineWebSocketTransportPolicy {
  /// Abridged packets use at most four framing bytes in addition to the bounded payload.
  public static let maximumIncomingMessageBytes = InlineSecureTransport.maximumPacketBytes + 4

  public static func makeTask(
    using session: URLSession,
    url: URL
  ) -> URLSessionWebSocketTask {
    let task = session.webSocketTask(with: url)
    task.maximumMessageSize = maximumIncomingMessageBytes
    return task
  }
}
