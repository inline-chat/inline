import Foundation
import InlineKit
import SwiftUI

struct HelpSettingsView: View {
  let onSelectSpace: (Int64) -> Void

  var body: some View {
    List {
      HelpCommunitySection(onSelectSpace: onSelectSpace)
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
  let onSelectSpace: (Int64) -> Void
  @State private var pendingAction: Action?
  @State private var errorMessage: String?

  var body: some View {
    Section("Community") {
      Button {
        pendingAction = .townHall
      } label: {
        HelpActionLabel(
          title: "Join Town Hall",
          description: "Community space",
          systemImage: "person.3",
          isPending: pendingAction == .townHall
        )
      }

      Button {
        pendingAction = .founderDM
      } label: {
        HelpActionLabel(
          title: "Message Mo",
          trailingValue: "@mo",
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
        router.dismissSheet()
        onSelectSpace(response.space.id)

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
    router.dismissSheet()
    router.openPrimaryDestination(destination)
  }
}

private struct HelpActionLabel: View {
  let title: LocalizedStringResource
  var description: LocalizedStringResource?
  var trailingValue: String?
  let systemImage: String
  let isPending: Bool

  var body: some View {
    HelpDetailRow(
      title: title,
      description: description,
      trailingValue: trailingValue,
      systemImage: systemImage,
      isPending: isPending
    )
  }
}

private struct HelpResourcesSection: View {
  var body: some View {
    Section("Resources") {
      HelpLinkRow(
        title: "Docs",
        description: "Guides and setup",
        systemImage: "book.closed",
        url: "https://inline.chat/docs"
      )
      HelpLinkRow(
        title: "What’s New",
        systemImage: "sparkles",
        url: "https://inline.chat/docs/changelog"
      )
      HelpLinkRow(
        title: "Website",
        trailingValue: "inline.chat",
        systemImage: "globe",
        url: "https://inline.chat"
      )
      HelpLinkRow(
        title: "GitHub",
        trailingValue: "inline-chat",
        systemImage: "chevron.left.forwardslash.chevron.right",
        url: "https://github.com/inline-chat"
      )
      HelpLinkRow(
        title: "Updates on X",
        trailingValue: "@inline_chat",
        systemImage: "at",
        url: "https://x.com/inline_chat"
      )
      HelpLinkRow(
        title: "Status",
        systemImage: "waveform.path.ecg",
        url: "https://status.inline.chat"
      )
    }
  }
}

private struct HelpAppSection: View {
  private let metadata = SettingsReleaseMetadata.current

  var body: some View {
    Section("About") {
      LabeledContent("Version") {
        Text("\(metadata.version) (\(metadata.build))")
          .monospacedDigit()
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
    Text("Inline \(metadata.version) (\(metadata.build))")
      .font(.caption2)
      .monospacedDigit()
      .foregroundStyle(.tertiary)
  }
}

private struct HelpLinkRow: View {
  let title: LocalizedStringResource
  var description: LocalizedStringResource?
  var trailingValue: String?
  let systemImage: String
  let url: String

  var body: some View {
    if let destination = URL(string: url) {
      Link(destination: destination) {
        HelpDetailRow(
          title: title,
          description: description,
          trailingValue: trailingValue,
          systemImage: systemImage
        )
      }
    }
  }
}

private struct HelpDetailRow: View {
  let title: LocalizedStringResource
  var description: LocalizedStringResource?
  var trailingValue: String?
  let systemImage: String
  var isPending = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .foregroundStyle(.primary)

        if let description {
          Text(description)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if isPending {
        ProgressView()
          .controlSize(.small)
      } else if let trailingValue {
        Text(trailingValue)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .contentShape(Rectangle())
  }
}

private enum HelpActionError: Error {
  case invalidResponse
}

private struct SettingsReleaseMetadata {
  let version: String
  let build: String

  static let current = SettingsReleaseMetadata(
    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
  )
}
