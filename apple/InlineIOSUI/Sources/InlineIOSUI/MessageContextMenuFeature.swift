import Foundation

/// Which context menu a message long press opens.
public enum MessageContextMenuImplementation: Equatable, Sendable {
  /// UIKit's `UIContextMenuInteraction`.
  case system
  /// Inline's own menu: live, selectable preview, Telegram-style scrolling and timing.
  case custom
}

public enum MessageContextMenuFeature {
  public static let preferenceKey = "experimental.iosCustomMessageContextMenu"

  public static func selectedImplementation(
    defaults: UserDefaults = .standard,
    isExperimentAvailable: Bool = true
  ) -> MessageContextMenuImplementation {
    isExperimentAvailable && defaults.bool(forKey: preferenceKey) ? .custom : .system
  }
}
