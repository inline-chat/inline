import AppKit

/// Copies a raw ID shown by Developer Mode (chat toolbar menu, Chat Info).
@MainActor
enum DeveloperIDs {
  static func copy(_ id: Int64, label: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(String(id), forType: .string) else {
      ToastCenter.shared.showError("Failed to copy \(label.lowercased())")
      return
    }
    ToastCenter.shared.showSuccess("Copied \(label.lowercased())")
  }
}
