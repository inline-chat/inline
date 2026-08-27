import Foundation
import InlineKit
import InlineProtocol
import Observation
import RealtimeV2
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Observable
private final class SpaceInviteLinkModel {
  let spaceID: Int64
  private let realtime: RealtimeV2
  var isAvailable = false
  var isLoading = false
  var isChanging = false
  var link: URL?
  var expiresAt: Date?
  var errorMessage: String?

  init(spaceID: Int64, realtime: RealtimeV2) {
    self.spaceID = spaceID
    self.realtime = realtime
  }

  var isPresentingError: Bool {
    get { errorMessage != nil }
    set {
      if !newValue {
        errorMessage = nil
      }
    }
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      let result = try await realtime.send(.getSpaceInviteLink(spaceId: spaceID))
      guard case let .getSpaceInviteLink(response) = result else { return }
      isAvailable = true
      apply(response.hasLink ? response.link : nil)
    } catch {
      // Only space admins can manage links. Keep this owner control absent for
      // everyone else instead of presenting a control that cannot work.
      isAvailable = false
    }
  }

  func setEnabled(_ enabled: Bool) async {
    guard !isChanging else { return }
    isChanging = true
    defer { isChanging = false }

    do {
      let result = try await realtime.send(.setSpaceInviteLinkEnabled(spaceId: spaceID, enabled: enabled))
      guard case let .setSpaceInviteLinkEnabled(response) = result else {
        throw SpaceJoinError.invalidResponse
      }
      apply(response.hasLink ? response.link : nil)
    } catch {
      errorMessage = "Couldn’t update the invite link. Please try again."
    }
  }

  private func apply(_ value: InlineProtocol.SpaceInviteLink?) {
    link = value.flatMap { URL(string: $0.url) }
    expiresAt = value.flatMap { $0.hasExpiresAt ? Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) : nil }
  }
}

struct SpaceInviteLinkButton: View {
  @State private var model: SpaceInviteLinkModel
  @State private var isPresented = false

  init(spaceID: Int64, realtime: RealtimeV2) {
    _model = State(initialValue: SpaceInviteLinkModel(spaceID: spaceID, realtime: realtime))
  }

  var body: some View {
    @Bindable var bindableModel = model

    ZStack {
      if model.isAvailable {
        Button("Invite Link", systemImage: "link") {
          isPresented.toggle()
        }
        .labelStyle(.iconOnly)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
          SpaceInviteLinkPopover(model: model)
          #if os(iOS)
            .presentationCompactAdaptation(.popover)
          #else
            .presentationSizing(.fitted)
          #endif
        }
        .accessibilityLabel("Invite Link")
        #if os(macOS)
          .help("Invite Link")
        #endif
      }
    }
    .task {
      await model.load()
    }
    .alert(
      "Couldn’t update invite link",
      isPresented: $bindableModel.isPresentingError
    ) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }
}

private struct SpaceInviteLinkPopover: View {
  let model: SpaceInviteLinkModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("Invite Link", systemImage: "link")
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
        if model.isChanging {
          ProgressView()
            .controlSize(.small)
        }
      }

      if let link = model.link {
        SpaceInviteLinkActiveContent(
          link: link,
          expiresAt: model.expiresAt,
          isChanging: model.isChanging,
          onDisable: { Task { await model.setEnabled(false) } }
        )
      } else {
        SpaceInviteLinkCreationContent(
          isChanging: model.isChanging,
          onCreate: { Task { await model.setEnabled(true) } }
        )
      }
    }
    .padding(16)
    .frame(idealWidth: 320, maxWidth: 360)
  }
}

private struct SpaceInviteLinkActiveContent: View {
  let link: URL
  let expiresAt: Date?
  let isChanging: Bool
  let onDisable: () -> Void

  var body: some View {
    Link(destination: link) {
      HStack(spacing: 8) {
        Text(link.absoluteString)
          .font(.callout.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "arrow.up.right")
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open Invite Link")

    if let expiresAt {
      Text("Expires \(expiresAt, format: .dateTime.month(.abbreviated).day().hour().minute())")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    ViewThatFits {
      HStack(spacing: 8) {
        copyButton
        shareButton
      }
      VStack(alignment: .leading, spacing: 8) {
        copyButton
        shareButton
      }
    }

    Divider()

    Button("Disable Link", role: .destructive, action: onDisable)
      .disabled(isChanging)
  }

  private var copyButton: some View {
    Button("Copy Link", systemImage: "doc.on.doc") {
      SpaceInviteLinkClipboard.copy(link.absoluteString)
    }
  }

  private var shareButton: some View {
    ShareLink(item: link) {
      Label("Share", systemImage: "square.and.arrow.up")
    }
  }
}

private struct SpaceInviteLinkCreationContent: View {
  let isChanging: Bool
  let onCreate: () -> Void

  var body: some View {
    Text("Create one link that people can use to join this space.")
      .font(.callout)
      .foregroundStyle(.secondary)

    Button("Create Invite Link", systemImage: "link.badge.plus", action: onCreate)
      .disabled(isChanging)
  }
}

private enum SpaceInviteLinkClipboard {
  static func copy(_ value: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    #else
    UIPasteboard.general.string = value
    #endif
  }
}
