import InlineCompatUI
import InlineKit
import InlineUI
import SwiftUI
import UIKit

/// Settings pages without a UIKit port yet, hosted through `SwiftUIBridge` on iOS 18+ only
/// (the bridge's own floor). Kept in one file so the other Settings files stay SwiftUI-free.
/// Delete an entry once its page is ported.
@MainActor
enum SettingsBridgedPages {
  static var isAvailable: Bool {
    if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) { return true }
    return false
  }

  @available(iOS 18.0, *)
  static func connectors(shell: MainShellController) -> UIViewController {
    SwiftUIBridge.controller(ConnectorsView(), shell: shell, title: String(localized: "Connectors"))
  }

  @available(iOS 18.0, *)
  static func bots(shell: MainShellController) -> UIViewController {
    SwiftUIBridge.controller(BotsSettingsView(), shell: shell, title: String(localized: "Bots"))
  }

  @available(iOS 18.0, *)
  static func debug(shell: MainShellController) -> UIViewController {
    SwiftUIBridge.controller(DebugView(), shell: shell, title: String(localized: "Debug"))
  }

  /// Privacy exception list editor (brings its own NavigationStack).
  @available(iOS 18.0, *)
  static func privacyPeopleEditor(
    shell: MainShellController,
    title: String,
    footer: String,
    selectedIDs: [Int64],
    onSave: @escaping ([Int64]) -> Void
  ) -> UIViewController {
    SwiftUIBridge.sheet(
      PrivacyPeopleEditor(title: title, footer: footer, selectedIDs: selectedIDs, onSave: onSave),
      shell: shell
    )
  }
}
