/// The next view renders every message it supports; the legacy cell covers the rest.
public enum MessageViewImplementation: Equatable, Sendable {
  case legacy
  case next
}
