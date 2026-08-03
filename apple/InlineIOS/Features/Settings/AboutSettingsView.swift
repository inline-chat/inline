import Foundation
import SwiftUI

struct AboutSettingsView: View {
  private let metadata = SettingsReleaseMetadata.current

  var body: some View {
    List {
      Section("App") {
        LabeledContent("Version") {
          VStack(alignment: .trailing, spacing: 2) {
            Text("\(metadata.version) (\(metadata.build))")
              .monospacedDigit()
            if let releaseDate = metadata.releaseDate {
              Text("Released \(releaseDate, format: .relative(presentation: .named))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Section("Inline") {
        AboutLinkRow(title: "Website", systemImage: "globe", url: "https://inline.chat")
        AboutLinkRow(title: "Status", systemImage: "waveform.path.ecg", url: "https://status.inline.chat")
        AboutLinkRow(title: "Documentation", systemImage: "book.closed", url: "https://inline.chat/docs")
        AboutLinkRow(title: "X", systemImage: "at", url: "https://x.com/inline_chat")
        AboutLinkRow(title: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/inline-chat")
      }

      Section("Legal") {
        AboutLinkRow(title: "Terms of Service", systemImage: "doc.text", url: "https://inline.chat/legal/terms")
        AboutLinkRow(title: "Privacy Policy", systemImage: "hand.raised", url: "https://inline.chat/legal/privacy")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("About Inline")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct SettingsReleaseSummary: View {
  private let metadata = SettingsReleaseMetadata.current

  var body: some View {
    VStack(spacing: 3) {
      Text("Inline \(metadata.version) (\(metadata.build))")
        .monospacedDigit()

      if let releaseDate = metadata.releaseDate {
        Text("Released \(releaseDate, format: .relative(presentation: .named))")
      }
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
  }
}

private struct AboutLinkRow: View {
  let title: LocalizedStringResource
  let systemImage: String
  let url: String

  var body: some View {
    if let destination = URL(string: url) {
      Link(destination: destination) {
        Label(title, systemImage: systemImage)
      }
    }
  }
}

private struct SettingsReleaseMetadata {
  let version: String
  let build: String
  let releaseDate: Date?

  static let current = SettingsReleaseMetadata(
    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
    releaseDate: releaseDateFromBundle()
  )

  private static func releaseDateFromBundle() -> Date? {
    // TODO: Have the release pipeline stamp an explicit release timestamp in
    // Info.plist. The executable modification date is a useful prototype fallback.
    guard let executableURL = Bundle.main.executableURL else { return nil }
    return try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }
}
