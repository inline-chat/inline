import InlineKit
import SwiftUI
import UIKit

/// Copies a raw ID shown by Developer Mode (chat top menu, Chat Info).
@MainActor
enum DeveloperIDs {
  struct Entry {
    let label: String
    let id: Int64
  }

  static func copy(_ id: Int64, label: String) {
    UIPasteboard.general.string = String(id)
    ToastManager.shared.showToast("Copied \(label.lowercased())", type: .success, systemImage: "number")
  }
}

/// Chat Info card listing IDs that copy on tap; hidden while Developer Mode is off.
struct DeveloperIDsCard: View {
  let entries: [DeveloperIDs.Entry]

  @AppStorage(DeveloperMode.key) private var developerMode = false

  var body: some View {
    if developerMode, !entries.isEmpty {
      VStack(spacing: 0) {
        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
          if index > 0 {
            Divider()
              .padding(.horizontal, 16)
          }
          Button {
            DeveloperIDs.copy(entry.id, label: entry.label)
          } label: {
            LabeledContent(entry.label) {
              Text(String(entry.id))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Copies the \(entry.label.lowercased())")
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
      }
      .background(Color(uiColor: .secondarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .padding(.horizontal, 16)
    }
  }
}
