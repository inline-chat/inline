import Foundation
import InlineKit
import SwiftUI

struct HelpSettingsView: View {
  var body: some View {
    List {
      HelpCommunitySection()
      HelpResourcesSection()
      HelpAppSection()
      HelpLegalSection()
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Help")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct HelpCommunitySection: View {
  private enum Action: Hashable {
    case townHall
    case founderDM
  }

  @Environment(Router.self) private var router
  @State private var pendingAction: Action?
  @State private var errorMessage: String?

  var body: some View {
    Section("Community") {
      Button {
        pendingAction = .townHall
      } label: {
        HelpActionLabel(
          title: "Join Town Hall",
          description: "Inline’s early users community",
          systemImage: "person.3",
          isPending: pendingAction == .townHall
        )
      }

      Button {
        pendingAction = .founderDM
      } label: {
        HelpActionLabel(
          title: "DM the Founder",
          description: "Start a DM with @mo",
          systemImage: "bubble.left",
          isPending: pendingAction == .founderDM
        )
      }
    }
    .disabled(pendingAction != nil)
    .task(id: pendingAction) {
      guard let pendingAction else { return }
      await perform(pendingAction)
    }
    .alert("Couldn’t Complete Action", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Please try again.")
    }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { isPresented in
        if !isPresented { errorMessage = nil }
      }
    )
  }

  private func perform(_ action: Action) async {
    defer { pendingAction = nil }
    do {
      switch action {
      case .townHall:
        let result = try await Api.realtime.send(.joinPublicSpace(handle: "townhall"))
        guard case let .joinPublicSpace(response) = result else {
          throw HelpActionError.invalidResponse
        }
        open(.space(id: response.space.id))

      case .founderDM:
        let userID = getDenaOrMoUserId(username: "mo")
        guard userID > 0 else { throw HelpActionError.invalidResponse }
        let peer = Peer.user(id: userID)
        _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: true))
        open(.chat(peer: peer))
      }
    } catch is CancellationError {
      return
    } catch {
      errorMessage = switch action {
      case .townHall: "Couldn’t join Town Hall. Please try again."
      case .founderDM: "Couldn’t start a DM with @mo. Please try again."
      }
    }
  }

  private func open(_ destination: Destination) {
    let tab = router.selectedTab
    router.dismissSheet()
    router.push(destination, for: tab)
  }
}

private struct HelpActionLabel: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  let systemImage: String
  let isPending: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Label(title, systemImage: systemImage)
        Text(description)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if isPending {
        ProgressView()
          .controlSize(.small)
      }
    }
    .contentShape(Rectangle())
  }
}

private struct HelpResourcesSection: View {
  var body: some View {
    Section("Resources") {
      HelpLinkRow(
        title: "Docs",
        description: "Get started, set up agents, and develop",
        systemImage: "book.closed",
        url: "https://inline.chat/docs"
      )
      HelpLinkRow(
        title: "What’s New",
        description: "The latest Inline changes",
        systemImage: "sparkles",
        url: "https://inline.chat/docs/changelog"
      )
      HelpLinkRow(
        title: "Website",
        description: "inline.chat",
        systemImage: "globe",
        url: "https://inline.chat"
      )
      HelpLinkRow(
        title: "GitHub",
        description: "Open-source tools and SDKs",
        systemImage: "chevron.left.forwardslash.chevron.right",
        url: "https://github.com/inline-chat"
      )
      HelpLinkRow(
        title: "Updates on X",
        description: "@inline_chat",
        systemImage: "at",
        url: "https://x.com/inline_chat"
      )
      HelpLinkRow(
        title: "Status",
        description: "System availability",
        systemImage: "waveform.path.ecg",
        url: "https://status.inline.chat"
      )
    }
  }
}

private struct HelpAppSection: View {
  private let metadata = SettingsReleaseMetadata.current

  var body: some View {
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
  }
}

private struct HelpLegalSection: View {
  var body: some View {
    Section("Legal") {
      HelpLinkRow(
        title: "Terms of Service",
        systemImage: "doc.text",
        url: "https://inline.chat/legal/terms"
      )
      HelpLinkRow(
        title: "Privacy Policy",
        systemImage: "hand.raised",
        url: "https://inline.chat/legal/privacy"
      )
    }
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

private struct HelpLinkRow: View {
  let title: LocalizedStringResource
  var description: LocalizedStringResource?
  let systemImage: String
  let url: String

  var body: some View {
    if let destination = URL(string: url) {
      Link(destination: destination) {
        VStack(alignment: .leading, spacing: 3) {
          Label(title, systemImage: systemImage)
          if let description {
            Text(description)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private enum HelpActionError: Error {
  case invalidResponse
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
