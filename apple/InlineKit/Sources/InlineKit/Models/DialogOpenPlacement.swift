import Foundation

/// The normal-lane edge used when a dialog becomes an Open Chats member.
///
/// Keep this independent from sidebar sort mode: recent-activity presentation
/// may temporarily override the visible order without changing the saved edge.
public enum DialogOpenPlacement: String, Codable, Sendable {
  case top
  case bottom

  /// Product default. Keep aligned with `defaultDialogOpenPlacement` on the server.
  public static let defaultValue: Self = .top
}
